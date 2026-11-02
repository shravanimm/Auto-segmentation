/* ============================================================================
   seg_run_all_viya.sas  -  one-click run of the SAS segmentation module
   (all five techniques + cross-technique top 10) on Viya.

   FILES NEEDED in your SAS Content folder (&base below):
       macros/                            <- every .sas file of sas_macros/autoseg_ucmacros
       data/development_data_5000_shap.csv
       data/monitoring_data_5000_shap.csv
   Change ONLY &base (line below) to your own SAS Content folder, then run all.
   Takes about 6-7 minutes (K-Means is the slow one).
   ============================================================================ */

/* ---- 0. reset, in case an earlier error left SAS in syntax-check mode ---- */
options obs=max nosyntaxcheck;
%let syscc=0;

/* ---- 1. locations (SAS Content) ---- */
%let base = /Users/sastest1/My Folder/autoseg;      /* <-- CHANGE to your folder */
filename segmac  filesrvc folderpath="&base/macros";
filename devcsv  filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv  filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";

/* ---- 2. compile the macros (needed once per SAS session) ----
   Log must end with: NOTE: All segmentation macros compiled from the segmac folder */
%include segmac(seg_compile_viya.sas);

/* ---- 3. load the data ---- */
proc import datafile=devcsv out=work.dev_data dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.mon_data dbms=csv replace; getnames=yes; guessingrows=max; run;

/* ---- 4. run all five techniques + cross-technique ranking ---- */
%csb_segmentation_calc_wrapper(
    dev_dta=work.dev_data, mon_dta=work.mon_data,
    techniques=AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type,
    as_max_combo_depth=2, as_beam_width=10, dt_max_depth=4, dt_min_samples_leaf=0.04,
    gb_n_estimators=50, km_k_min=8, km_k_max=12, km_min_cluster_pct=0.02, out_prefix=seg);

/* ---- 5. results ---- */
title "Run log (status per technique)";
proc print data=seg_run_log noobs; run;

title "Cross-technique top 10";
proc print data=seg_cross_top10 noobs;
    var Overall_Rank Technique Segment_Definition Normalized_Root_Cause_Score Root_Cause_Feature; run;

title "AutoSlicer top segments";
proc print data=seg_autoslicer_segments noobs;
    var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Feature Root_Cause_Score; run;
title;
