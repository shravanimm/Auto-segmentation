/* ============================================================================
   seg_execute_viya.sas  -  PARITY CHECK of the SAS module against the Python reference.
   (For a normal run use seg_run_all_viya.sas - the minimal trigger.)

   Pins the exact settings of the Python benchmark through the global variables (sg_cfg_*)
   and the six hand-picked columns, so SAS can be compared with the saved Python results.
   FILES in your SAS Content folder (&base):  macros/  data/  golden/
   Run the sections ONE AT A TIME and read the log after each.
   ============================================================================ */
%let base = /Users/sastest1/My Folder/autoseg;   /* <-- your SAS Content folder */
filename segmac  filesrvc folderpath="&base/macros";
filename devcsv  filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv  filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";

/* ---- SECTION 1: compile (log must show: All segmentation macros compiled) ---- */
options obs=max nosyntaxcheck;
%let syscc=0;
%include segmac(seg_compile_viya.sas);

/* ---- SECTION 2: load data and pin the benchmark settings (fixed values, no grid search) ---- */
proc import datafile=devcsv out=work.dev_data dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.mon_data dbms=csv replace; getnames=yes; guessingrows=max; run;

%let sg_cfg_optimize = N;
%let sg_cfg_as_depth = 2;  %let sg_cfg_as_beam = 10; %let sg_cfg_as_bins = 4;
%let sg_cfg_dt_depth = 4;  %let sg_cfg_dt_min_leaf = 0.04;
%let sg_cfg_gb_nest  = 50; %let sg_cfg_gb_depth = 3;
%let sg_cfg_km_k_min = 8;  %let sg_cfg_km_k_max = 12; %let sg_cfg_km_min_cluster_pct = 0.02;

/* Column overrides so the data matches the Python benchmark (normally NOT needed) */
%macro run_one(tech=, golden=, sas_prefix=);
    %csb_segmentation_calc_wrapper(
        dev_dta=work.dev_data, mon_dta=work.mon_data, target_col=default_flag, techniques=&tech,
        score_col=pd_score, weight_col=ead,
        feature_cols=age region employment_type bureau_score dti utilization,
        numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
        shap_cols=shap_age shap_bureau_score shap_dti shap_utilization shap_region shap_employment_type);
    %if %length(&golden) %then %do;
        filename gpool filesrvc folderpath="&base/golden" filename="golden_&golden._pool.csv";
        filename gtop  filesrvc folderpath="&base/golden" filename="golden_&golden._top.csv";
        %seg_compare_to_golden(golden_pool=gpool, golden_top=gtop,
                               sas_pool=&sas_prefix._pool, sas_top=&sas_prefix._segments);
    %end;
%mend run_one;

/* ---- SECTION 3: AutoSlicer ---- */
%run_one(tech=AUTOSLICER, golden=autoslicer, sas_prefix=seg_autoslicer);
/* ---- SECTION 4: Drift Tree ---- */
%run_one(tech=DRIFT_TREE, golden=drift_tree, sas_prefix=seg_drifttree);
/* ---- SECTION 5: Gradient Boosting ---- */
%run_one(tech=GRADIENT_BOOSTING, golden=gradient_boosting, sas_prefix=seg_gradboost);
/* ---- SECTION 6: Feature Binning (compare top segments by eye) ---- */
%run_one(tech=FEATURE_BINNING, golden=, sas_prefix=seg_featbin);
title "Feature Binning top segments (SAS)";
proc print data=seg_featbin_segments noobs; var Rank Segment_Definition Dev_Count Mon_Count Root_Cause_Score Significant; run;
title;
