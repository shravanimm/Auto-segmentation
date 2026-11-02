/* ============================================================================
   seg_score_candidates.sas
   SAS port of core/candidate_ranking.compute_severity_scores - the scoring
   shared by AutoSlicer, Drift Tree, Gradient Boosting and K-Means.

   Over the WHOLE evaluated pool (so the pool must match Python's to match):
     * BH-adjusted p-values for bad-rate and score-shift tests
     * Business_Impact_Score, SIS, DIS, DIS_Symmetric (metrics/business_metrics)
     * min-max normalisation of SIS, DIS, mean_feature_psi, mean_shap_shift
     * root_cause_score = .35 nSIS + .30 nDIS + .20 nPSI + .15 nSHAP
     * Severity_Score = round(root_cause_score*20, 4)
     * Statistically_Significant = adj p (bad rate) <= alpha OR adj p (KS) <= alpha
     * Drift_Explanation text, Portfolio_Impact_Score
   in  : evaluated pool (seg_evaluate_candidates columns + Segment_Definition)
   out : same rows + scoring columns (names identical to the Python records)
   ============================================================================ */
%macro seg_score_candidates(in=, out=, alpha=0.05);

    %local sis_lo sis_hi dis_lo dis_hi psi_lo psi_hi shp_lo shp_hi;

    %seg_bh(in=&in, pvar=br_pvalue,          adjvar=p_br_adj, out=_sg_bh1);
    %seg_bh(in=&in, pvar=score_shift_pvalue, adjvar=p_ks_adj, out=_sg_bh2);

    proc sort data=&in out=_sg_sc0; by cand_id; run;

    data _sg_sc1;
        merge _sg_sc0 _sg_bh1 _sg_bh2;
        by cand_id;
        bus_impact = (pct_mon * mon_weight_pct) * (1 + psi + max(0, -delta_gini));
        auc_drop   = max(0, -delta_auc);
        conf       = min(1, sqrt(max(0, n_mon) / 100));
        ef         = ifn(mon_weight_pct > 0, mon_weight_pct, 1);
        popd       = pct_mon - pct_dev;
        sis        = auc_drop * ef * pct_mon * conf;
        dis        = max(0, popd * auc_drop * ef * (1 + max(0, mean_feature_psi)));
        dis_sym    = abs(popd) * auc_drop * ef * (1 + max(0, mean_feature_psi));
    run;

    proc sql noprint;
        select min(sis) format=best32., max(sis) format=best32., min(dis) format=best32., max(dis) format=best32., min(mean_feature_psi) format=best32., max(mean_feature_psi) format=best32.,
               min(mean_shap_shift) format=best32., max(mean_shap_shift) format=best32.
          into :sis_lo trimmed, :sis_hi trimmed, :dis_lo trimmed, :dis_hi trimmed,
               :psi_lo trimmed, :psi_hi trimmed, :shp_lo trimmed, :shp_hi trimmed
          from _sg_sc1;
    quit;

    data &out;
        set _sg_sc1;
        length PSI_Interpretation $60 Drift_Explanation $1000 _t $400;

        /* metrics/significance.min_max_normalize: zeros when range < 1e-9 */
        if &sis_hi - &sis_lo < 1e-9 then n_sis = 0; else n_sis = (sis - &sis_lo) / (&sis_hi - &sis_lo);
        if &dis_hi - &dis_lo < 1e-9 then n_dis = 0; else n_dis = (dis - &dis_lo) / (&dis_hi - &dis_lo);
        if &psi_hi - &psi_lo < 1e-9 then n_psi = 0; else n_psi = (mean_feature_psi - &psi_lo) / (&psi_hi - &psi_lo);
        if &shp_hi - &shp_lo < 1e-9 then n_shp = 0; else n_shp = (mean_shap_shift - &shp_lo) / (&shp_hi - &shp_lo);

        rcs = 0.35 * n_sis + 0.30 * n_dis + 0.20 * n_psi + 0.15 * n_shp;

        BadRate_pvalue_adj    = ifn(missing(p_br_adj), 1, p_br_adj);
        ScoreShift_pvalue_adj = ifn(missing(p_ks_adj), 1, p_ks_adj);
        Statistically_Significant = (BadRate_pvalue_adj <= &alpha) or (ScoreShift_pvalue_adj <= &alpha);

        Business_Impact_Score = round(bus_impact, 0.0001);
        SIS_Raw         = round(sis, 0.000001);
        DIS_Raw         = round(dis, 0.000001);
        DIS_Symmetric   = round(dis_sym, 0.000001);
        Confidence_Score = round(conf, 0.0001);
        root_cause_score = round(rcs, 0.000001);
        Severity_Score   = round(rcs * 20, 0.0001);
        Portfolio_Impact_Score = round(ifn(missing(delta_gini), 0, pct_mon * abs(delta_gini)), 0.000001);

        if psi < 0.1 then PSI_Interpretation = 'Population Share: Stable';
        else if psi <= 0.25 then PSI_Interpretation = 'Population Share: Moderate Drift';
        else PSI_Interpretation = 'Population Share: Significant Drift';

        /* _build_drift_reasons() */
        Drift_Explanation = '';
        if psi > 0.10 then do;
            _t = 'Population shift (Dev ' || strip(put(100 * pct_dev, 8.1)) || '% -> Mon '
                 || strip(put(100 * pct_mon, 8.1)) || '%, PSI ' || strip(put(psi, 12.4)) || ')';
            Drift_Explanation = catx(' | ', Drift_Explanation, _t);
        end;
        if not missing(delta_gini) and delta_gini < -0.05 then do;
            _t = 'Gini drop ' || strip(put(abs(delta_gini), 12.4)) || ' (Dev ' || strip(put(gini_dev, 12.4))
                 || ' -> Mon ' || strip(put(gini_mon, 12.4)) || ')';
            Drift_Explanation = catx(' | ', Drift_Explanation, _t);
        end;
        if not missing(delta_ks) and delta_ks < -0.05 then do;
            _t = 'KS drop ' || strip(put(abs(delta_ks), 12.4)) || ' (Dev ' || strip(put(ks_dev, 12.4))
                 || ' -> Mon ' || strip(put(ks_mon, 12.4)) || ')';
            Drift_Explanation = catx(' | ', Drift_Explanation, _t);
        end;
        if not missing(delta_br) and abs(delta_br) > 0.03 and BadRate_pvalue_adj <= &alpha then do;
            _t = 'Significant bad-rate shift (Dev ' || strip(put(100 * br_dev, 8.2)) || '% -> Mon '
                 || strip(put(100 * br_mon, 8.2)) || '%, p_adj=' || strip(put(BadRate_pvalue_adj, 12.4)) || ')';
            Drift_Explanation = catx(' | ', Drift_Explanation, _t);
        end;
        if psi < 0.10 and not missing(delta_gini) and abs(delta_gini) >= 0.05 then do;
            _t = 'Population share stable (low PSI) but the score no longer separates risk inside this segment -- concept drift, not exposure drift';
            Drift_Explanation = catx(' | ', Drift_Explanation, _t);
        end;
        if missing(Drift_Explanation) then Drift_Explanation = 'Segment performance stable';

        drop p_br_adj p_ks_adj bus_impact auc_drop conf ef popd sis dis dis_sym n_sis n_dis n_psi n_shp rcs _t;
    run;

%mend seg_score_candidates;
