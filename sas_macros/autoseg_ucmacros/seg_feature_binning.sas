/* ============================================================================
   seg_feature_binning.sas
   SAS port of techniques/feature_binning.py (FeatureBinningTechnique.run).

   1  seg_fb_strength   keep legitimate features, rank by |AUC-0.5|, top max_features
   2  bins              numeric: missing bin + best-first supervised bins
                        categorical: per-category or bad-rate-ordered groups
                        (seg_fb_bins_num / seg_fb_bins_cat)
   3  gates             dev and mon count >= max(30, int(N*min_bin_pct)) and
                        dev and mon share <= max_segment_pct   (NO event-count gate,
                        unlike the other four techniques)
   4  metrics           shared engine (AUC/Gini/KS, bad rate, PSI, exposure,
                        in-segment feature PSI, SHAP) + FB calibration/ECE
   5  bootstrap         the bootstrap_top_n candidates with the largest mean |delta|
                        get n_iter bootstrap p-values (seg_fb_bootstrap)
   6  score             bootstrapped pool and remainder scored SEPARATELY
                        (seg_fb_score), then ranked together by final score
   7  de-dup + top_n    Jaccard de-dup over the whole ranked list, keep top_n
   Public table differences vs the other techniques: Feature, Bin_Type,
   calibration intercept/slope/ECE columns, Significant (not
   Statistically_Significant), Overall_Score, no portfolio view. Root_Cause_Feature
   is the binned feature itself and Root_Cause_PSI its population-share PSI.
   Defaults equal models/config.FeatureBinningConfig.
   NOT reproducible bit-for-bit: bootstrap RNG (SAS RAND vs numpy), logistic
   intercept/slope optimiser. Bins, candidate pool and point metrics ARE exact.
   ============================================================================ */
%macro seg_feature_binning(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                           max_features=30, max_bins=8, min_bin_pct=0.01, max_segment_pct=0.35,
                           overlap_jaccard_threshold=0.70, top_n=20, bootstrap_top_n=40,
                           n_iter=50, alpha=0.10, seed=42, rca_name_filter=Y, out_prefix=seg_fb);

    %global sg_fb_nbin;
    %local nf i f vt mind minm nboot;

    %seg_prep(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
              weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
              max_segment_pct=&max_segment_pct, rca_name_filter=&rca_name_filter);
    %let sg_premem = Y;

    /* ---- 1. features ---- */
    %seg_fb_strength(feature_cols=&feature_cols, max_features=&max_features);

    /* ---- 2. bins ---- */
    data _fb_bin;
        length bin_id 8 feat_idx 8 feature $64 btype $10 lower 8 upper 8 lo_inf 8 hi_inf 8 label $400;
        stop;
    run;
    data _fb_cat; length bin_id 8 value $200; stop; run;
    %let sg_fb_nbin = 0;
    %let nf = %sysfunc(countw(&sg_fb_sel, %str( )));
    %do i = 1 %to &nf;
        %let f  = %scan(&sg_fb_sel, &i, %str( ));
        %let vt = %seg_vartype(ds=_sg_dev, var=&f);
        %if &vt = N %then %seg_fb_bins_num(f=&f, i=&i, max_bins=&max_bins, min_bin_pct=&min_bin_pct);
        %else %seg_fb_bins_cat(f=&f, i=&i, max_bins=&max_bins, min_bin_pct=&min_bin_pct);
    %end;
    %put NOTE: seg_feature_binning - &sg_fb_nbin candidate bins over &nf features.;

    %seg_fb_membership(feature_cols=&sg_fb_sel);
    data _fb_cand0(keep=cand_id); set _fb_bin; cand_id = bin_id; run;

    /* ---- 3. gates (point_estimate_metrics) ---- */
    data _null_;
        call symputx('mind', max(30, int(&sg_ndev * &min_bin_pct)), 'L');
        call symputx('minm', max(30, int(&sg_nmon * &min_bin_pct)), 'L');
    run;
    %seg_membership(side=dev, cand=_fb_cand0, out=_fb_ml_dev, cols=_y);
    %seg_membership(side=mon, cand=_fb_cand0, out=_fb_ml_mon, cols=_y);
    proc sql;
        create table _fb_surv as
        select d.cand_id
        from (select cand_id, count(*) as n from _fb_ml_dev group by cand_id) d
             inner join (select cand_id, count(*) as n from _fb_ml_mon group by cand_id) m
             on d.cand_id = m.cand_id
        where d.n >= &mind and m.n >= &minm
          and d.n / &sg_ndev <= &max_segment_pct and m.n / &sg_nmon <= &max_segment_pct
        order by d.cand_id;
    quit;

    proc datasets lib=work nolist nowarn; delete _sg_pool _sg_memmon_all _sg_rules_all _sg_fpsi_all; quit;

    %if %seg_nobs(_fb_surv) = 0 %then %do;
        %put NOTE: seg_feature_binning - no bin passed the count gates.;
        %seg_publish(technique=Feature Binning, out_prefix=&out_prefix, top_n=&top_n);
        %let sg_premem = N;
        %return;
    %end;

    /* ---- 4. metrics ---- */
    %seg_evaluate_candidates(cand=_fb_surv, out=_fb_ev, shap_cols=&shap_cols);
    %seg_fb_calib(mem_dev=_sg_mem_dev, mem_mon=_sg_mem_mon, out=_fb_cal);

    proc sql;
        create table _fb_pt as
        select e.*, c.cal_dev_intercept, c.cal_mon_intercept, c.delta_intercept,
               c.cal_dev_slope, c.cal_mon_slope, c.delta_slope, c.ece_dev, c.ece_mon, c.delta_ece,
               b.feat_idx, b.feature, b.btype, b.label as Segment_Definition,
               b.lower as bin_lower, b.upper as bin_upper
        from _fb_ev e left join _fb_cal c on e.cand_id = c.cand_id
             inner join _fb_bin b on e.cand_id = b.bin_id
        order by e.cand_id;
    quit;

    /* ---- 5. bootstrap the strongest candidates ---- */
    data _fb_rough;
        set _fb_pt(keep=cand_id delta_gini delta_ks delta_auc delta_br delta_ece);
        rough = mean(abs(delta_gini), abs(delta_ks), abs(delta_auc), abs(delta_br), abs(delta_ece));
        if missing(rough) then rough = 0;
    run;
    proc sort data=_fb_rough; by descending rough cand_id; run;
    data _fb_boot(keep=cand_id) _fb_rest(keep=cand_id);
        set _fb_rough;
        if _n_ <= &bootstrap_top_n then output _fb_boot; else output _fb_rest;
    run;
    %let nboot = %seg_nobs(_fb_boot);

    %seg_fb_bootstrap(cand=_fb_boot, n_iter=&n_iter, seed=&seed, out=_fb_bs);

    proc sort data=_fb_boot; by cand_id; run;
    proc sort data=_fb_rest; by cand_id; run;
    data _fb_p1;
        merge _fb_pt _fb_boot(in=_b) _fb_bs;
        by cand_id;
        if _b;
    run;
    data _fb_p2;
        merge _fb_pt _fb_rest(in=_r);
        by cand_id;
        if _r;
        array pp [15] gini_ci_low gini_ci_high gini_p ks_ci_low ks_ci_high ks_p auc_ci_low auc_ci_high
                      auc_p br_ci_low br_ci_high br_p ece_ci_low ece_ci_high ece_p;
        do _i = 1 to 15; pp[_i] = .; end;
        drop _i;
    run;

    /* ---- 6. score the two pools separately, rank together ---- */
    %seg_fb_score(in=_fb_p1, out=_fb_s1, apply_bh=Y, alpha=&alpha);
    %if %seg_nobs(_fb_p2) > 0 %then %do;
        %seg_fb_score(in=_fb_p2, out=_fb_s2, apply_bh=N, alpha=&alpha);
        data _fb_scored; set _fb_s1 _fb_s2; run;
    %end;
    %else %do;
        data _fb_scored; set _fb_s1; run;
    %end;

    /* ---- 7. de-dup over the whole ranked list, top_n ---- */
    data _sg_memmon_all(keep=cand_id _rid); set _sg_mem_mon; run;
    %seg_rank_dedup(in=_fb_scored, mem_mon=_sg_memmon_all, out=_fb_dd, overlap=&overlap_jaccard_threshold,
                    pool_size=%seg_nobs(_fb_scored), dedup=Y,
                    sortby=%str(descending final_score descending deterioration_score cand_id));

    data _fb_top; set _fb_dd(obs=&top_n); Rank = dedup_rank; run;

    /* ---- public tables ---- */
    data &out_prefix._segments;
        length Technique $40 Rank 8 Feature $64 Segment_Definition $400 Bin_Type $10;
        set _fb_top;
        Technique = 'Feature Binning';
        Feature = feature;
        Bin_Type = btype;
        Dev_Count = n_dev; Mon_Count = n_mon; Dev_Pct = pct_dev; Mon_Pct = pct_mon;
        PSI = psi; PSI_Interpretation = psi_interpretation;
        Dev_AUC = auc_dev; Mon_AUC = auc_mon; Delta_AUC = delta_auc;
        Dev_Gini = gini_dev; Mon_Gini = gini_mon; Delta_Gini = delta_gini;
        Dev_KS = ks_dev; Mon_KS = ks_mon; Delta_KS = delta_ks;
        Dev_BR = br_dev; Mon_BR = br_mon; Delta_BR = delta_br;
        Dev_Calibration_Intercept = cal_dev_intercept; Mon_Calibration_Intercept = cal_mon_intercept;
        Delta_Calibration_Intercept = delta_intercept;
        Dev_Calibration_Slope = cal_dev_slope; Mon_Calibration_Slope = cal_mon_slope;
        Delta_Calibration_Slope = delta_slope;
        Dev_ECE = ece_dev; Mon_ECE = ece_mon; Delta_ECE = delta_ece;
        Dev_EAD = weight_dev; Mon_EAD = weight_mon;
        Exposure_Pct = mon_weight_pct; Dev_Exposure_Pct = dev_weight_pct; Exposure_Drift = exposure_drift;
        Mon_Default_Count = x_mon;
        Deterioration_Score = deterioration_score; Confidence_Score = confidence_score;
        Significant = significant; SIS_Raw = round(sis_raw, 0.000001); DIS_Raw = round(dis_raw, 0.000001);
        Business_Impact_Score = business_impact_score;
        Overall_Score = final_score;
        Root_Cause_Feature = feature; Root_Cause_PSI = psi;
        Root_Cause_Score = round(root_cause_score_raw, 0.000001);
        keep Technique Rank Feature Segment_Definition Bin_Type Dev_Count Mon_Count Dev_Pct Mon_Pct
             PSI PSI_Interpretation Dev_AUC Mon_AUC Delta_AUC Dev_Gini Mon_Gini Delta_Gini
             Dev_KS Mon_KS Delta_KS Dev_BR Mon_BR Delta_BR Dev_Calibration_Intercept
             Mon_Calibration_Intercept Delta_Calibration_Intercept Dev_Calibration_Slope
             Mon_Calibration_Slope Delta_Calibration_Slope Dev_ECE Mon_ECE Delta_ECE Dev_EAD Mon_EAD
             Exposure_Pct Dev_Exposure_Pct Exposure_Drift Mon_Default_Count Deterioration_Score
             Confidence_Score Significant SIS_Raw DIS_Raw Business_Impact_Score Overall_Score
             Root_Cause_Feature Root_Cause_PSI Root_Cause_Score cand_id
             gini_ci_low gini_ci_high gini_p ks_ci_low ks_ci_high ks_p auc_ci_low auc_ci_high auc_p
             br_ci_low br_ci_high br_p ece_ci_low ece_ci_high ece_p min_p_adj
             mean_feature_psi mean_shap_shift top_drift_feature;
    run;

    %seg_fix_case(ds=&out_prefix._segments, names=Feature Significant PSI Delta_AUC Delta_Gini Delta_KS
                  Delta_BR);

    proc sql;
        /* exact bin definitions: numeric (lower, upper], missing, or one row per category */
        create table &out_prefix._rules as
        select t.Rank, t.cand_id, b.feature,
               case b.btype when 'numeric' then 'N' when 'missing' then 'M' else 'C' end as ptype length=1,
               b.lower, b.upper, b.lo_inf, b.hi_inf, c.value, b.label
        from _fb_top t inner join _fb_bin b on t.cand_id = b.bin_id
             left join _fb_cat c on b.bin_id = c.bin_id
        order by t.Rank, c.value;

        create table &out_prefix._feature_psi as
        select t.Rank, f.cand_id, f.feature, f.psi
        from _fb_top t inner join _sg_fpsi f on t.cand_id = f.cand_id
        order by t.Rank, f.feat_idx;
    quit;

    data &out_prefix._pool; set _fb_scored; run;

    data &out_prefix._log;
        technique = 'Feature Binning';
        total_dev_n = &sg_ndev; total_mon_n = &sg_nmon;
        features_evaluated = &nf; candidate_bins = &sg_fb_nbin;
        candidates_evaluated = %seg_nobs(_fb_pt); bootstrapped = &nboot;
        candidates_returned = %seg_nobs(&out_prefix._segments);
        run_datetime = datetime(); format run_datetime datetime20.;
    run;

    %let sg_premem = N;

%mend seg_feature_binning;
