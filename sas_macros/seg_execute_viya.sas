/* ============================================================================
   seg_execute_viya.sas  -  run the SAS segmentation module from SAS Content
   (SAS Data and AI Studio / SAS Studio, Viya compute server).

   ONE-TIME SETUP - upload these into SAS Content (Explorer > Files and folders
   > SAS Content > your folder > Upload), keeping this layout:
       /Users/<your id>/AutoSeg/macros   <- ALL files of the .sas files of sas_macros/autoseg_ucmacros
       /Users/<your id>/AutoSeg/data     <- data/development_data_5000_shap.csv
                                            data/monitoring_data_5000_shap.csv
       /Users/<your id>/AutoSeg/golden   <- every file of the .csv files of sas_macros/parity/golden
   Then change ONLY the next line (&base) and run the sections below ONE AT A
   TIME (select the section, press Run), reading the log after each.
   ============================================================================ */
%let base = /Users/sastest1/My Folder/autoseg;   /* <-- your SAS Content folder */

filename segmac  filesrvc folderpath="&base/macros";
filename devcsv  filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv  filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";

/* ---------------------------------------------------------------- SECTION 1
   Compile all macros. Log must show: "NOTE: All segmentation macros compiled".
   Any ERROR here = a macro file failed to compile -> send me the log. */
%include segmac(seg_compile_viya.sas);

/* ---------------------------------------------------------------- SECTION 2
   Load the demo data */
proc import datafile=devcsv out=work.dev_data dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.mon_data dbms=csv replace; getnames=yes; guessingrows=max; run;

/* ---------------------------------------------------------------- SECTION 3
   SMOKE TEST: AutoSlicer only (about a minute). Must finish without ERROR
   and produce seg_autoslicer_segments with 10 rows. */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data, techniques=AUTOSLICER,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    as_max_combo_depth=2, as_beam_width=10, as_numeric_bins=4, out_prefix=seg);

title "Run log";     proc print data=seg_run_log noobs; run;
title "AutoSlicer top segments";
proc print data=seg_autoslicer_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Feature Root_Cause_Score; run;
title;

/* ---------------------------------------------------------------- SECTION 4
   PARITY CHECK vs Python (the important one). Wants: verdict PASS on every row
   (the ks and score_shift rows use the loose tolerance) and top_positions_identical=10 */
filename gpool filesrvc folderpath="&base/golden" filename="golden_autoslicer_pool.csv";
filename gtop  filesrvc folderpath="&base/golden" filename="golden_autoslicer_top.csv";
%seg_compare_to_golden(golden_pool=gpool, golden_top=gtop,
                       sas_pool=seg_autoslicer_pool, sas_top=seg_autoslicer_segments);

/* ---------------------------------------------------------------- SECTION 5
   DRIFT TREE (seconds) + parity */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data, techniques=DRIFT_TREE,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    dt_max_depth=4, dt_min_samples_leaf=0.04, out_prefix=seg);
filename gpool filesrvc folderpath="&base/golden" filename="golden_drift_tree_pool.csv";
filename gtop  filesrvc folderpath="&base/golden" filename="golden_drift_tree_top.csv";
%seg_compare_to_golden(golden_pool=gpool, golden_top=gtop,
                       sas_pool=seg_drifttree_pool, sas_top=seg_drifttree_segments);

/* ---------------------------------------------------------------- SECTION 6
   GRADIENT BOOSTING (50 trees, a few minutes) + parity */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data, techniques=GRADIENT_BOOSTING,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    gb_n_estimators=50, gb_max_depth=3, out_prefix=seg);
filename gpool filesrvc folderpath="&base/golden" filename="golden_gradient_boosting_pool.csv";
filename gtop  filesrvc folderpath="&base/golden" filename="golden_gradient_boosting_top.csv";
%seg_compare_to_golden(golden_pool=gpool, golden_top=gtop,
                       sas_pool=seg_gradboost_pool, sas_top=seg_gradboost_segments);

/* ---------------------------------------------------------------- SECTION 7
   K-MEANS (several minutes; not identical to Python by design) */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data, techniques=KMEANS,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    km_k_min=8, km_k_max=12, km_min_cluster_pct=0.02, out_prefix=seg);
title "K-Means diagnostics"; proc print data=seg_kmeans_k_diagnostics noobs; run;
title "K-Means top segments"; proc print data=seg_kmeans_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Score Rule_Precision Rule_Recall; run;
title;

/* ---------------------------------------------------------------- SECTION 8
   FEATURE BINNING (about a minute; bootstrap => not identical by design) */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data, techniques=FEATURE_BINNING,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    out_prefix=seg);
title "Feature Binning top segments"; proc print data=seg_featbin_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Score Significant; run;
title;

/* ---------------------------------------------------------------- SECTION 9
   Everything at once + cross-technique top 10 (only after 3-8 look sane) */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data,
    techniques=AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    as_max_combo_depth=2, as_beam_width=10, dt_max_depth=4, dt_min_samples_leaf=0.04,
    gb_n_estimators=50, km_k_min=8, km_k_max=12, km_min_cluster_pct=0.02, out_prefix=seg);
title "Run log"; proc print data=seg_run_log noobs; run;
title "Cross-technique top 10";
proc print data=seg_cross_top10 noobs;
    var Overall_Rank Technique Segment_Definition Normalized_Root_Cause_Score Root_Cause_Feature; run;
title;
