/* ============================================================================
   seg_run_viz_viya.sas  -  CHARTS of the segmentation module in SAS and SAS Visual Analytics

   What it does (run the sections ONE AT A TIME):
     1. compile the macros
     2. run the module (fast settings) so there are result tables to draw
     3. prepare chart-ready tables                   (seg_viz_prepare / seg_viz_prepare_trend)
     4. draw the Python project's figures with SAS   (seg_viz_charts -> Results tab)
     5. publish the tables to CAS for Visual Analytics (seg_viz_publish_cas)
     6. READ the tables back from CAS and draw again  (seg_viz_from_cas)
     7. (optional) trend charts, needs the v2 monthly files
   See VISUAL_ANALYTICS_GUIDE.md for building the Visual Analytics report on the CAS tables.
   ============================================================================ */
options obs=max nosyntaxcheck;
%let syscc=0;
%let base = /Users/sastest1/My Folder/autoseg;      /* <-- CHANGE to your folder */
filename segmac filesrvc folderpath="&base/macros";

/* ---- 1. compile ---- */
%include segmac(seg_compile_viya.sas);

/* ---- 2. a quick run to have results (Drift Tree + Feature Binning, fixed parameters) ---- */
filename devcsv filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";
proc import datafile=devcsv out=work.dev_data dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.mon_data dbms=csv replace; getnames=yes; guessingrows=max; run;

%let sg_cfg_optimize   = N;
%let sg_cfg_exclude_cols = lgd_actual;
%csb_segmentation_run(dev_dta=work.dev_data, mon_dta=work.mon_data, target_col=default_flag,
                      trend=N, techniques=DRIFT_TREE FEATURE_BINNING, weight_col=ead);

/* ---- 3. chart-ready tables from the cross-technique top 10 ----
   (any segment table works: seg_<tech>_segments, seg_cross_top10, or segtr_summary for the trend run) */
%seg_viz_prepare(seg=seg_cross_top10, out=viz);

title "viz_bubble";    proc print data=viz_bubble noobs; run;
title "viz_heatmap (first rows)"; proc print data=viz_heatmap(obs=12) noobs; run;
title "viz_waterfall (top segment)"; proc print data=viz_waterfall(where=(seg_id=1)) noobs; run;
title;

/* ---- 4. the figures with PROC SGPLOT (bubble, heatmap, SIS waterfall of segment 1) ----
   to save the images: ods listing gpath="<a server folder>";  before this call */
%seg_viz_charts(viz=viz, charts=BUBBLE HEATMAP WATERFALL, wf_seg=1);

/* ---- 5. publish to CAS (promoted, so Visual Analytics can use them) ----
   new_session=Y starts a CAS session; use N if your program already has one */
%seg_viz_publish_cas(viz=viz, caslib=casuser, tables=bubble heatmap waterfall, persist=Y, new_session=Y);

/* ---- 6. read the tables back from CAS and draw the charts from them ----
   proves the tables in CAS are complete; this is what any other SAS job can do */
%seg_viz_from_cas(viz=viz, caslib=casuser, charts=BUBBLE HEATMAP WATERFALL);

/* ---- 7. TREND charts (optional): needs the v2 data and a trend run ---- */
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

%csb_segmentation_run(dev_dta=work.dev_v2, mon_dta=work.mon_all, target_col=default_flag,
                      trend=Y, period_col=month, techniques=AUTOSLICER FEATURE_BINNING);

%seg_viz_prepare(seg=segtr_summary, out=vizt);                       /* bubble / heatmap / waterfall on trend scores */
%seg_viz_prepare_trend(series=segtr_series, periods=segtr_periods, forecast=segtr_forecast, out=vizt);
%seg_viz_charts(viz=vizt, charts=BUBBLE HEATMAP WATERFALL TIMESERIES EARLY, wf_seg=1, ts_seg=1);
%seg_viz_publish_cas(viz=vizt, caslib=casuser, tables=bubble heatmap waterfall timeseries early_warning, persist=Y, new_session=N);
