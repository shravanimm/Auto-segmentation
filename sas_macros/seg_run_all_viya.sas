/* ============================================================================
   seg_run_all_viya.sas  -  run the SAS segmentation module with the MINIMAL TRIGGER.
   Same flow as the Streamlit "Compare All Segmentation Techniques" tab:
       1. Run trend analysis?   trend = N | Y
       2. Which techniques?     techniques = ...   (cross-technique ranking is built from them)
   Everything else (score, weight, SHAP, features, depth, bins, beam ...) is detected, defaulted
   (global sg_cfg_* variables, see seg_config.sas) or auto-optimised.
   Change ONLY &base, then run section by section.
   ============================================================================ */

/* ---- 0. reset, in case an earlier error left SAS in syntax-check mode ---- */
options obs=max nosyntaxcheck;
%let syscc=0;

/* ---- 1. locations (SAS Content) ---- */
%let base = /Users/sastest1/My Folder/autoseg;      /* <-- CHANGE to your folder */
filename segmac  filesrvc folderpath="&base/macros";

/* ---- 2. compile the macros (once per SAS session) ----
   Log must end with: NOTE: All segmentation macros compiled from the segmac folder */
%include segmac(seg_compile_viya.sas);

/* ---- 3. global settings (optional - anything not set here uses the default in seg_config.sas) ---- */
%let sg_cfg_optimize = N;        /* N = fixed parameters (fast)   Y = auto-optimise by grid search (slow) */

/* ============================================================================
   A.  TREND ANALYSIS = NO   -  one development table vs one monitoring table
   ============================================================================ */
filename devcsv  filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv  filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";
proc import datafile=devcsv out=work.dev_data dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.mon_data dbms=csv replace; getnames=yes; guessingrows=max; run;

%csb_segmentation_run(
    dev_dta    = work.dev_data,
    mon_dta    = work.mon_data,
    target_col = default_flag,
    trend      = N,
    techniques = AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING FEATURE_BINNING,   /* add KMEANS when ready */
    weight_col = ead                                                        /* temporary override */
);

title "1. Run log (status per technique)";                   proc print data=seg_run_log noobs label; run;
title "2. What the engine detected - role and reason";       proc print data=seg_schema noobs label; var column_name role source reason; run;
title "3. Parameters chosen (every combination tried)";
data work.all_param_search;
    set seg_autoslicer_param_search seg_drifttree_param_search seg_gradboost_param_search seg_featbin_param_search;
run;
proc print data=work.all_param_search noobs label; var technique combo parameters objective_score selected selection_rule; run;
title "4. Settings used";                                    proc print data=seg_run_config noobs label; run;
title "5. Cross-technique top 10";
proc print data=seg_cross_top10 noobs label;
    var Overall_Rank Technique Segment_Definition Normalized_Root_Cause_Score Root_Cause_Feature Discovered_By; run;
title "6. AutoSlicer top segments - in plain English";
proc print data=seg_autoslicer_segments noobs label; var Rank Segment_Definition Segment_Summary Segment_Where_Clause; run;
title;

/* ============================================================================
   B.  TREND ANALYSIS = YES  -  development table vs a monitoring table with several periods
       needs in &base/data: v2_development_data.csv and v2_monitoring_2026_01..06.csv (column "month")
   ============================================================================ */
filename devcsv2 filesrvc folderpath="&base/data" filename="v2_development_data.csv";
proc import datafile=devcsv2 out=work.dev_v2 dbms=csv replace; getnames=yes; guessingrows=max; run;
%macro load_months;
    %local m;
    %do m = 1 %to 6;
        filename mcsv filesrvc folderpath="&base/data" filename="v2_monitoring_2026_0&m..csv";
        proc import datafile=mcsv out=work.mon_&m dbms=csv replace; getnames=yes; guessingrows=max; run;
    %end;
    data work.mon_all; set work.mon_1 work.mon_2 work.mon_3 work.mon_4 work.mon_5 work.mon_6; run;
%mend load_months;
%load_months;

%csb_segmentation_run(
    dev_dta    = work.dev_v2,
    mon_dta    = work.mon_all,
    target_col = default_flag,
    trend      = Y,
    period_col = month,
    techniques = AUTOSLICER FEATURE_BINNING
);

title "T1. Period log";                      proc print data=segtr_period_log noobs label; run;
title "T2. Recurring segments (trend summary)";
proc sort data=segtr_summary out=work._t_sorted; by descending Periods_Appeared descending Severity_Score_Trend; run;
proc print data=work._t_sorted(obs=20) noobs label;
    var Technique Segment_Definition Periods_Appeared Appeared_In Trend_Impact_Score Severity_Score_Trend; run;
title "T3. Cross-technique top 10 on trend-boosted scores";
proc print data=segtr_cross_top10 noobs label;
    var Overall_Rank Technique Segment_Definition Normalized_Root_Cause_Score Discovered_By; run;
title "T4. Early-warning forecast";          proc print data=segtr_forecast(obs=15) noobs label; run;
title;
