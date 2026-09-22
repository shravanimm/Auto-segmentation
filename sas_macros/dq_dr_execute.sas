/* ============================================================================
   dq_dr_execute.sas
   The ONE file to open and run for the full DQ + Drift pipeline. Everything
   else it needs lives under autoseg_ucmacros/ (one macro per file) and gets
   compiled by dq_dr_compile.sas in a single step below.

   Local / base-SAS usage (this file): set &_autoseg_ucmacros to the folder
   path and %include the compile file, as done below.

   SAS Viya / SAS Content usage: replace the two lines below with:
       filename dq_dr filesrvc folderpath="/Public/AutoSegmentation/autoseg_ucmacros";
       %include dq_dr;
   which compiles every macro file in that Content folder in one shot -
   functionally identical, just using the Viya-native folder-fileref instead
   of an explicit file list.

   Adjust the libname/PROC IMPORT paths below to wherever your dev/mon CSVs
   live, or point straight at existing SAS/CAS tables (e.g.
   public.v2_development_data) and skip the IMPORT step entirely.
   ============================================================================ */

%let _autoseg_ucmacros = /replace/with/full/path/to/autosegmentation/sas_macros/autoseg_ucmacros;
%include "&_autoseg_ucmacros/dq_dr_compile.sas";

/* ---- Load the CSVs into SAS datasets (skip this if already in a library) ---- */
libname public "%sysfunc(pathname(work))";  /* replace with your real library */

proc import datafile="C:\Users\ad51324\Downloads\dataa\v2_development_data.csv"
            out=public.dev_data dbms=csv replace;
    getnames=yes;
run;

proc import datafile="C:\Users\ad51324\Downloads\dataa\v2_monitoring_2026_01.csv"
            out=public.mon_data dbms=csv replace;
    getnames=yes;
run;

/* ---- Run it: one call, everything (DQ dev+mon, and full drift suite) ---- */
%csb_dq_dr_calc_wrapper(
    dev_dta       = public.dev_data,
    mon_dta       = public.mon_data,
    is_dq_req     = Y,
    is_drift_req  = Y,
    order         = DQ_FIRST,
    target_col    = default_flag,
    score_col     = pd_score,
    id_cols       = customer_id,
    private_cols  = age,
    feature_cols  = age annual_income bureau_score dti utilization ltv ead lgd_actual,
    categorical_cols = region employment_type industry
);

/* ---- Inspect results ---- */
title "DQ - Development data: blockers";
proc print data=dq_dev_blockers noobs; run;

title "DQ - Development data: governance flags";
proc print data=dq_dev_governance noobs; run;

title "DQ - Development data: health score & readiness";
proc print data=dq_dev_health noobs; run;

title "Drift - schema changes (dev vs mon)";
proc print data=drift_schema noobs;
    where change_type ne "unchanged";
run;

title "Drift - completeness drift";
proc print data=drift_completeness noobs; run;

title "Drift - CSI per feature";
proc print data=drift_csi noobs; run;

title "Drift - score-level PSI (System Stability Index)";
proc print data=drift_score_psi noobs; run;

title "Drift - target/event-rate drift";
proc print data=drift_target noobs; run;

title "Drift - categorical PSI";
proc print data=drift_categorical_psi noobs; run;

title "Drift - entropy drift (categorical)";
proc print data=drift_entropy noobs; run;

title "Drift - approximate KS per feature";
proc print data=drift_ks noobs; run;

title "Drift - distribution stats (std/CV/kurtosis/quantile drift)";
proc print data=drift_distribution noobs; run;
