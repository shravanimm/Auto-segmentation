/* ============================================================================
   seg_execute_trend_viya.sas  -  TREND ANALYSIS: parity check against Python, then a demo run.

   (PART A needs golden CSVs in SAS Content - if you have no golden folder run seg_trend_parity.sas instead, it embeds them)
   PART A (deterministic, fast): feeds the Python history table to seg_trend_metrics and
           seg_trend_forecast and compares every number with the Python results.
           Needs in &base/golden:  golden_trend_history.csv  golden_trend_periods.csv
                                   golden_trend_summary.csv  golden_trend_forecast.csv
           (created by  python sas_macros/parity/export_trend_golden.py)
   PART B  (optional): the real thing - one segmentation run per monitoring period.
           Needs the v2 data in &base/data:  v2_development_data.csv and the monthly files
           v2_monitoring_2026_01.csv ... v2_monitoring_2026_06.csv (column "month" = period).
   Run the sections ONE AT A TIME and read the log after each.
   ============================================================================ */
%let base = /Users/sastest1/My Folder/autoseg;   /* <-- your SAS Content folder */
filename segmac  filesrvc folderpath="&base/macros";

/* ---- SECTION 1: compile ---- */
options obs=max nosyntaxcheck;
%let syscc=0;
%include segmac(seg_compile_viya.sas);
%seg_config;

/* ============================== PART A: PARITY ============================== */
/* ---- SECTION 2: load the Python reference ---- */
filename g_hist filesrvc folderpath="&base/golden" filename="golden_trend_history.csv";
filename g_per  filesrvc folderpath="&base/golden" filename="golden_trend_periods.csv";
filename g_sum  filesrvc folderpath="&base/golden" filename="golden_trend_summary.csv";
filename g_fc   filesrvc folderpath="&base/golden" filename="golden_trend_forecast.csv";
data work.g_hist;
    infile g_hist dsd firstobs=2 truncover;
    length Technique $40 Segment_Definition $1000 Period $60;
    input Technique $ Segment_Definition $ Period $ Period_Index Severity_Score Root_Cause_Score
          SIS_Raw DIS_Raw mean_feature_psi mean_shap_shift;
run;
data work.g_per;
    infile g_per dsd firstobs=2 truncover;
    length Period $60;
    input Period_Index Period $;
run;
proc import datafile=g_sum  out=work.g_sum  dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=g_fc   out=work.g_fc   dbms=csv replace; getnames=yes; guessingrows=max; run;

/* ---- SECTION 3: run the SAS macros on the Python history (Python defaults pinned) ---- */
%seg_trend_metrics(hist=work.g_hist, periods=work.g_per, out=work.t_sum,
                   half_life=2, w_freq=0.4, w_rec=0.3, w_cons=0.3, trend_weight=0.5);
%seg_trend_forecast(series=work.g_hist, out=work.t_fc, alert=0.5, horizon=6);

/* ---- SECTION 4: compare ---- */
proc sql;
    create table work.c_sum as
    select a.Technique, a.Segment_Definition,
           abs(a.Periods_Appeared - b.Periods_Appeared) as d_app,
           abs(a.Frequency - b.Frequency) as d_freq,
           abs(a.Recency_Factor - b.Recency_Factor) as d_rec,
           abs(a.Consistency_Score - b.Consistency_Score) as d_cons,
           abs(a.Trend_Impact_Score - b.Trend_Impact_Score) as d_tis,
           abs(a.SIS_Trend - b.SIS_Trend) as d_sist,
           abs(a.Root_Cause_Score_Trend - b.Root_Cause_Score_Trend) as d_rcst,
           abs(a.Severity_Score_Trend - b.Severity_Score_Trend) as d_sevt,
           (a.Appeared_In ne b.Appeared_In) as d_appin
    from work.g_sum a inner join work.t_sum b
         on a.Technique = b.Technique and a.Segment_Definition = b.Segment_Definition;
    create table work.c_fc as
    select a.Technique, a.Segment_Definition,
           abs(a.Periods_Used - b.Periods_Used) as d_n,
           abs(a.Current_Root_Cause_Score - b.Current_Root_Cause_Score) as d_cur,
           abs(a.Predicted_Next_Root_Cause_Score - b.Predicted_Next_Root_Cause_Score) as d_pred,
           abs(a.Predicted_Next_Lower95 - b.Predicted_Next_Lower95) as d_lo,
           abs(a.Predicted_Next_Upper95 - b.Predicted_Next_Upper95) as d_up,
           abs(a.Trend_Slope - b.Trend_Slope) as d_slope,
           abs(a.R_Squared - b.R_Squared) as d_r2,
           abs(a.Trend_P_Value - b.Trend_P_Value) as d_p,
           abs(a.Months_To_Breach - b.Months_To_Breach) as d_mtb,
           ((a.Months_To_Breach is null) ne (b.Months_To_Breach is null)) as d_mtb_null,
           ((upcase(strip(a.Early_Warning)) = 'TRUE') ne (b.Early_Warning = 1)) as d_ew,
           (a.Confidence ne b.Confidence) as d_conf
    from work.g_fc a inner join work.t_fc b
         on a.Technique = b.Technique and a.Segment_Definition = b.Segment_Definition;
quit;
data work.c_sum; set work.c_sum; d_all = max(d_app, d_freq, d_rec, d_cons, d_tis, d_sist, d_rcst, d_sevt); run;
data work.c_fc;  set work.c_fc;  d_all = max(d_n, d_cur, d_pred, d_lo, d_up, d_slope, d_r2, d_p, d_mtb); run;

title "Trend parity: rows matched (Python vs SAS)";
proc sql;
    select (select count(*) from work.g_sum) as py_summary, (select count(*) from work.t_sum) as sas_summary,
           (select count(*) from work.c_sum) as matched_summary,
           (select count(*) from work.g_fc) as py_forecast, (select count(*) from work.t_fc) as sas_forecast,
           (select count(*) from work.c_fc) as matched_forecast from work.g_per(obs=1);
quit;
title "Largest absolute difference per metric - summary (all should be about 0; PASS when below 1e-4)";
proc sql;
    select max(d_app) as Periods_Appeared, max(d_freq) as Frequency, max(d_rec) as Recency,
           max(d_cons) as Consistency, max(d_tis) as Trend_Impact, max(d_sist) as SIS_Trend,
           max(d_rcst) as RC_Score_Trend, max(d_sevt) as Severity_Trend, sum(d_appin) as Appeared_In_mismatch,
           case when max(d_all) < 0.0001 and sum(d_appin) = 0 then 'PASS' else 'FAIL' end as verdict
    from work.c_sum;
title "Largest absolute difference per metric - forecast";
proc sql;
    select max(d_n) as Periods_Used, max(d_cur) as Current, max(d_pred) as Predicted, max(d_lo) as Lower95,
           max(d_up) as Upper95, max(d_slope) as Slope, max(d_r2) as R2, max(d_p) as P_value,
           max(d_mtb) as Months_To_Breach, sum(d_mtb_null) as MTB_null_mismatch, sum(d_ew) as Early_Warning_mismatch,
           sum(d_conf) as Confidence_mismatch,
           case when max(d_all) < 0.0002
                 and sum(d_mtb_null) = 0 and sum(d_ew) = 0 and sum(d_conf) = 0 then 'PASS' else 'FAIL' end as verdict
    from work.c_fc;
title;

/* ============================== PART B: REAL PERIOD RUNS ============================== */
/* ---- SECTION 5: load development + 6 monthly monitoring files ---- */
filename devcsv filesrvc folderpath="&base/data" filename="v2_development_data.csv";
proc import datafile=devcsv out=work.dev_v2 dbms=csv replace; getnames=yes; guessingrows=max; run;
%macro load_months;
    %local m;
    %do m = 1 %to 6;
        filename mcsv filesrvc folderpath="&base/data" filename="v2_monitoring_2026_0&m..csv";
        proc import datafile=mcsv out=work.mon_&m dbms=csv replace; getnames=yes; guessingrows=max; run;
    %end;
    data work.mon_all; set work.mon_1 work.mon_2 work.mon_3 work.mon_4 work.mon_5 work.mon_6; run;
%mend load_months;
%load_months;
proc freq data=work.mon_all; tables month; run;     /* check: 6 periods */

/* ---- SECTION 6: trend run (fast settings first; remove them for the full auto-optimised run) ---- */
%let sg_cfg_optimize   = N;
%let sg_cfg_techniques = DRIFT_TREE FEATURE_BINNING;
%csb_segmentation_trend_wrapper(dev_dta=work.dev_v2, mon_dta=work.mon_all, period_col=month,
                                target_col=default_flag);

title "Period log";                         proc print data=segtr_period_log noobs label; run;
title "Recurring segments (trend summary)"; proc print data=segtr_summary(obs=15) noobs label;
    var Technique Segment_Definition Periods_Appeared Appeared_In Trend_Impact_Score Severity_Score_Trend; run;
title "Early-warning forecast";             proc print data=segtr_forecast(obs=15) noobs label; run;
title;
