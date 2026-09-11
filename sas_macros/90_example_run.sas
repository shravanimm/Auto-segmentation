/* ============================================================================
   90_example_run.sas
   Example call, using the actual mock dev/monitoring columns from this
   project (customer_id, age, region, ..., pd_score, default_flag[, month]).

   Adjust the libname/PROC IMPORT paths to wherever your dev/mon CSVs live,
   or point straight at existing SAS/CAS tables (e.g. public.v2_development_data)
   and skip the IMPORT step entirely.
   ============================================================================ */

%include "sas_macros/10_dq_macros.sas";
%include "sas_macros/20_drift_macros.sas";
%include "sas_macros/00_main_wrapper.sas";

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

/* ---- Run it ---- */
%main_wrapper(
    dev_dta       = public.dev_data,
    mon_dta       = public.mon_data,
    is_dq_req     = Y,
    is_drift_req  = Y,
    order         = DQ_FIRST,
    target_col    = default_flag,
    score_col     = pd_score,
    id_cols       = customer_id,
    private_cols  = age,
    feature_cols  = age annual_income bureau_score dti utilization ltv ead lgd_actual
);

/* ---- Inspect results ---- */
title "DQ — Development data: blockers";
proc print data=dq_dev_blockers noobs; run;

title "DQ — Development data: governance flags";
proc print data=dq_dev_governance noobs; run;

title "DQ — Development data: health score & readiness";
proc print data=dq_dev_health noobs; run;

title "Drift — schema changes (dev vs mon)";
proc print data=drift_schema noobs;
    where change_type ne "unchanged";
run;

title "Drift — completeness drift";
proc print data=drift_completeness noobs; run;

title "Drift — CSI per feature";
proc print data=drift_csi noobs; run;

title "Drift — score-level PSI (System Stability Index)";
proc print data=drift_score_psi noobs; run;

title "Drift — target/event-rate drift";
proc print data=drift_target noobs; run;
