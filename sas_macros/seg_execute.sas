/* ============================================================================
   seg_execute.sas
   Run + validate the SAS segmentation module end to end (all five techniques).
   Needs only a Viya COMPUTE session (Base SAS) - no CAS, no Risk Modeling.

   STEP 0 (once, any machine with the repo + Python):
       python sas_macros/parity/export_golden.py
     -> sas_macros/parity/golden/golden_<technique>_{pool,top}.csv
   STEP 1: set the three paths below. STEP 2: run this file section by section.

   WHAT TO EXPECT
     AutoSlicer, Drift Tree, Gradient Boosting : the candidate pool must match
        Python (seg_compare_to_golden: PASS on every metric; KS and the KS
        p-value use the documented loose tolerance).
     K-Means, Feature Binning : NOT identical by construction (random streams,
        logistic optimiser) - compare the top segments / chosen k / ranking
        shape with the golden *_top.csv by eye (section 3).
   Timing (5,000-row demo): AutoSlicer ~1 min, Drift Tree seconds, Gradient
   Boosting (50 trees) ~2-3 min, K-Means (k 8-12, n_init 10) several minutes,
   Feature Binning ~1 min.
   ============================================================================ */

%let _autoseg_ucmacros = /replace/with/path/to/autosegmentation/sas_macros/autoseg_ucmacros;
%let _data_dir         = /replace/with/path/to/autosegmentation/data;
%let _golden_dir       = /replace/with/path/to/autosegmentation/sas_macros/parity/golden;

%include "&_autoseg_ucmacros/seg_compile.sas";

proc import datafile="&_data_dir/development_data_5000_shap.csv" out=work.dev_data dbms=csv replace;
    getnames=yes; guessingrows=max;
run;
proc import datafile="&_data_dir/monitoring_data_5000_shap.csv" out=work.mon_data dbms=csv replace;
    getnames=yes; guessingrows=max;
run;

/* ------------------------------------------------------------------------
   1. Run all five techniques with the same settings as
      compare_segmentation_techniques.benchmark_all_techniques
   ------------------------------------------------------------------------ */
%csb_segmentation_calc_wrapper(
    dev_dta          = work.dev_data,
    mon_dta          = work.mon_data,
    techniques       = AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
    target_col       = default_flag,
    score_col        = pd_score,
    weight_col       = ead,
    feature_cols     = age region employment_type bureau_score dti utilization,
    numeric_cols     = age bureau_score dti utilization,
    categorical_cols = region employment_type,
    shap_cols        = shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    /* AutoSlicer */ as_max_combo_depth = 2, as_beam_width = 10, as_numeric_bins = 4,
    /* Drift Tree */ dt_max_depth = 4, dt_min_samples_leaf = 0.04,
    /* Grad.Boost */ gb_n_estimators = 50, gb_max_depth = 3,
    /* K-Means    */ km_k_min = 8, km_k_max = 12, km_min_cluster_pct = 0.02,
    out_prefix       = seg
);

title "Run log"; proc print data=seg_run_log noobs; run;
title "Cross-technique top 10 (ranked by normalised Root_Cause_Score)";
proc print data=seg_cross_top10 noobs;
    var Overall_Rank Technique Segment_Definition Normalized_Root_Cause_Score Root_Cause_Feature;
run;
title;

/* ------------------------------------------------------------------------
   2. Parity vs Python for the deterministic techniques
   ------------------------------------------------------------------------ */
%seg_compare_to_golden(
    golden_pool = &_golden_dir/golden_autoslicer_pool.csv,
    golden_top  = &_golden_dir/golden_autoslicer_top.csv,
    sas_pool    = seg_autoslicer_pool,  sas_top = seg_autoslicer_segments);

%seg_compare_to_golden(
    golden_pool = &_golden_dir/golden_drift_tree_pool.csv,
    golden_top  = &_golden_dir/golden_drift_tree_top.csv,
    sas_pool    = seg_drifttree_pool,   sas_top = seg_drifttree_segments);

%seg_compare_to_golden(
    golden_pool = &_golden_dir/golden_gradient_boosting_pool.csv,
    golden_top  = &_golden_dir/golden_gradient_boosting_top.csv,
    sas_pool    = seg_gradboost_pool,   sas_top = seg_gradboost_segments);

/* ------------------------------------------------------------------------
   3. K-Means and Feature Binning: eyeball against Python's top segments
   ------------------------------------------------------------------------ */
title "K-Means: chosen k and diagnostics"; proc print data=seg_kmeans_k_diagnostics noobs; run;
title "K-Means top segments (SAS)";        proc print data=seg_kmeans_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Score Rule_Precision Rule_Recall; run;
title "Feature Binning top segments (SAS)"; proc print data=seg_featbin_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Score Significant; run;
title;
proc import datafile="&_golden_dir/golden_kmeans_top.csv" out=work.py_km dbms=csv replace; run;
proc import datafile="&_golden_dir/golden_feature_binning_top.csv" out=work.py_fb dbms=csv replace; run;
title "K-Means top segments (Python)";         proc print data=work.py_km(obs=10) noobs;
    var Segment_Definition Dev_Count Mon_Count Root_Cause_Score; run;
title "Feature Binning top segments (Python)"; proc print data=work.py_fb(obs=10) noobs;
    var Segment_Definition Dev_Count Mon_Count Root_Cause_Score; run;
title;
