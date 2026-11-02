/* ============================================================================
   seg_evaluate_candidates.sas
   SAS port of core/candidate_evaluation.evaluate_segment for MANY candidates
   at once (set-based: one long membership table, group-by cand_id), shared by
   all techniques. Per candidate:
     counts/shares, population-share PSI, bad rate + two-proportion z-test,
     AUC/Gini/KS (dev & mon, deltas = mon - dev), calibration drift (A/E ratio
     shift), score-shift KS p-value, exposure share + drift, in-segment feature
     PSI (mean + top feature), mean SHAP shift.
   Output column names equal the Python evaluate_segment dict keys.

   cand : surviving candidates (cand_id, c1..cN)  - see seg_candidate_filter
   out  : one row per candidate
   Side output: _sg_mem_mon_kept (cand_id,_rid) mon membership, appended by the
   caller for Jaccard de-duplication.
   Requires: sg_ndev sg_nmon sg_twdev sg_twmon sg_rca_feats
   ============================================================================ */
%macro seg_evaluate_candidates(cand=, out=, shap_cols=);

    %seg_membership(side=dev, cand=&cand, out=_sg_mem_dev, cols=_rid _y _s _w &sg_rca_feats &shap_cols);
    %seg_membership(side=mon, cand=&cand, out=_sg_mem_mon, cols=_rid _y _s _w &sg_rca_feats &shap_cols);

    proc sql;
        create table _sg_bd as
        select cand_id, count(*) as n_dev, sum(_y) as x_dev, sum(_s) as sum_s_dev, sum(_w) as w_dev
        from _sg_mem_dev group by cand_id order by cand_id;
        create table _sg_bm as
        select cand_id, count(*) as n_mon, sum(_y) as x_mon, sum(_s) as sum_s_mon, sum(_w) as w_mon
        from _sg_mem_mon group by cand_id order by cand_id;
    quit;

    data _sg_cnt;
        merge _sg_bd(keep=cand_id n_dev) _sg_bm(keep=cand_id n_mon);
        by cand_id;
    run;

    %seg_auc_ks(mem=_sg_mem_dev, out=_sg_akd);
    %seg_auc_ks(mem=_sg_mem_mon, out=_sg_akm);
    %seg_ks_shift(mem_dev=_sg_mem_dev, mem_mon=_sg_mem_mon, cnt=_sg_cnt, out=_sg_ksh);
    %seg_feature_psi(mem_dev=_sg_mem_dev, mem_mon=_sg_mem_mon, feats=&sg_rca_feats, cnt=_sg_cnt,
                     out_long=_sg_fpsi, out_agg=_sg_fagg);
    %seg_shap_shift(mem_dev=_sg_mem_dev, mem_mon=_sg_mem_mon, shap_cols=&shap_cols, cnt=_sg_cnt,
                    out=_sg_shp);

    data &out;
        merge _sg_bd _sg_bm
              _sg_akd(rename=(auc=auc_dev ks=ks_dev))
              _sg_akm(rename=(auc=auc_mon ks=ks_mon))
              _sg_ksh(keep=cand_id score_shift_pvalue)
              _sg_fagg _sg_shp;
        by cand_id;

        pct_dev = n_dev / &sg_ndev;
        pct_mon = n_mon / &sg_nmon;

        /* single-bin PSI contribution (metrics/drift_metrics.calculate_psi) */
        _d = max(pct_dev, 1e-6);
        _m = max(pct_mon, 1e-6);
        psi = (_m - _d) * log(_m / _d);

        br_dev   = x_dev / n_dev;
        br_mon   = x_mon / n_mon;
        delta_br = br_mon - br_dev;

        /* two-proportion z-test (metrics/significance.two_proportion_ztest_pvalue) */
        _pp    = (x_dev + x_mon) / (n_dev + n_mon);
        _denom = _pp * (1 - _pp) * (1 / n_dev + 1 / n_mon);
        if _denom <= 0 then br_pvalue = .;
        else br_pvalue = 2 * (1 - probnorm(abs(((x_mon / n_mon) - (x_dev / n_dev)) / sqrt(_denom))));

        gini_dev = ifn(missing(auc_dev), ., 2 * auc_dev - 1);
        gini_mon = ifn(missing(auc_mon), ., 2 * auc_mon - 1);
        if missing(auc_dev) or missing(auc_mon)   then delta_auc  = .; else delta_auc  = auc_mon  - auc_dev;
        if missing(gini_dev) or missing(gini_mon) then delta_gini = .; else delta_gini = gini_mon - gini_dev;
        if missing(ks_dev) or missing(ks_mon)     then delta_ks   = .; else delta_ks   = ks_mon   - ks_dev;

        /* A/E ratio shift (metrics/performance_metrics.calculate_calibration_drift) */
        calibration_drift = x_mon / max(sum_s_mon, 1e-6) - x_dev / max(sum_s_dev, 1e-6);

        weight_dev     = w_dev;
        weight_mon     = w_mon;
        dev_weight_pct = ifn(&sg_twdev > 0, w_dev / &sg_twdev, 0);
        mon_weight_pct = ifn(&sg_twmon > 0, w_mon / &sg_twmon, 0);
        exposure_drift = mon_weight_pct - dev_weight_pct;

        drop _d _m _pp _denom sum_s_dev sum_s_mon w_dev w_mon;
    run;

%mend seg_evaluate_candidates;
