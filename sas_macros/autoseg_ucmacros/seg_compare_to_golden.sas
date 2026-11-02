/* ============================================================================
   seg_compare_to_golden.sas
   Parity check: SAS AutoSlicer output vs the Python reference written by
   sas_macros/parity/export_autoslicer_golden.py.

   Pool rows are matched on Segment_Definition; rows whose label differs only
   by display rounding (e.g. 33 vs 33.01, see seg_fmtnum) are matched on the
   fingerprint (n_dev, n_mon, x_dev, x_mon). Then the max absolute difference
   per metric is reported against a tolerance:
     tight  (default 1e-6): everything except the columns below
     loose  (default 5e-2): ks_dev ks_mon delta_ks (tie handling) and
            score_shift_pvalue / ScoreShift_pvalue_adj (asymptotic vs exact p)
   Round-off note: golden SIS/DIS/Severity are rounded to 4-6 dp in Python, so
   the tight tolerance for those is 1e-4 (tol_rounded).
   Prints PASS/FAIL per metric plus match counts and top-N order agreement.
   ============================================================================ */
%macro seg_compare_to_golden(golden_pool=, golden_top=, sas_pool=, sas_top=,
                             tol=1e-6, tol_rounded=1e-4, tol_loose=5e-2);

    %local num loose rounded i v n tolv;
    %let num = n_dev n_mon pct_dev pct_mon x_dev x_mon psi br_dev br_mon delta_br br_pvalue
               auc_dev auc_mon delta_auc gini_dev gini_mon delta_gini ks_dev ks_mon delta_ks
               score_shift_pvalue weight_dev weight_mon dev_weight_pct mon_weight_pct
               exposure_drift calibration_drift mean_feature_psi top_drift_psi mean_shap_shift
               BadRate_pvalue_adj ScoreShift_pvalue_adj Business_Impact_Score SIS_Raw DIS_Raw
               root_cause_score Severity_Score Portfolio_Impact_Score;
    %let loose   = ks_dev ks_mon delta_ks score_shift_pvalue ScoreShift_pvalue_adj;
    %let rounded = Business_Impact_Score SIS_Raw DIS_Raw root_cause_score Severity_Score Portfolio_Impact_Score;
    %let n = %sysfunc(countw(&num, %str( )));

    /* golden_pool / golden_top: a FILEREF (e.g. filesrvc) or a quoted-able server path */
    %if %sysfunc(fileref(&golden_pool)) = 0 %then %do;
        proc import datafile=&golden_pool out=_gp dbms=csv replace; guessingrows=max; run;
    %end;
    %else %do;
        proc import datafile="&golden_pool" out=_gp dbms=csv replace; guessingrows=max; run;
    %end;
    %if %sysfunc(fileref(&golden_top)) = 0 %then %do;
        proc import datafile=&golden_top out=_gt dbms=csv replace; guessingrows=max; run;
    %end;
    %else %do;
        proc import datafile="&golden_top" out=_gt dbms=csv replace; guessingrows=max; run;
    %end;

    data _gpk;
        set _gp;
        length g_label $1000 g_feat $64;
        g_label = Segment_Definition;
        g_feat  = top_drift_feature;
        g_sig   = (upcase(strip(vvalue(Statistically_Significant))) in ('TRUE', '1'));
        %do i = 1 %to &n; %let v = %scan(&num, &i, %str( )); g_&v = &v; %end;
        keep g_label g_feat g_sig g_:;
    run;

    data _spk;
        set &sas_pool;
        length s_label $1000 s_feat $64;
        s_label = Segment_Definition;
        s_feat  = top_drift_feature;
        s_sig   = Statistically_Significant;
        %do i = 1 %to &n; %let v = %scan(&num, &i, %str( )); s_&v = &v; %end;
        keep s_label s_feat s_sig s_:;
    run;

    proc sql;
        create table _cmA as select * from _gpk g inner join _spk s on g.g_label = s.s_label;
        create table _cmB as
            select * from (select * from _gpk where g_label not in (select s_label from _spk)) g
            inner join (select * from _spk where s_label not in (select g_label from _gpk)) s
            on g.g_n_dev = s.s_n_dev and g.g_n_mon = s.s_n_mon and g.g_x_dev = s.s_x_dev and g.g_x_mon = s.s_x_mon;
        create table _cmall as select * from _cmA outer union corr select * from _cmB;
        select (select count(*) from _gpk)  as golden_rows,
               (select count(*) from _spk)  as sas_rows,
               (select count(*) from _cmA)  as matched_by_label,
               (select count(*) from _cmB)  as matched_by_fingerprint
        from _gpk(obs=1);
    quit;

    data _cmd;
        set _cmall;
        %do i = 1 %to &n;
            %let v = %scan(&num, &i, %str( ));
            if missing(g_&v) and missing(s_&v) then d_&v = 0;
            else if missing(g_&v) or missing(s_&v) then d_&v = 9999;
            else d_&v = abs(g_&v - s_&v);
        %end;
        d_sig  = (g_sig ne s_sig);
        d_feat = (g_feat ne s_feat);
    run;

    proc means data=_cmd noprint;
        var d_:;
        output out=_cmmax(drop=_type_ _freq_) max=;
    run;

    proc transpose data=_cmmax out=_cmsum(rename=(_name_=metric col1=max_abs_diff)); run;

    data _cmsum;
        set _cmsum;
        length verdict $8;
        metric = substr(metric, 3);
        if metric in ('sig', 'feat') then tolv = 0;
        else if findw("&loose", strip(metric), ' ') then tolv = &tol_loose;
        else if findw("&rounded", strip(metric), ' ') then tolv = &tol_rounded;
        else tolv = &tol;
        verdict = ifc(max_abs_diff <= tolv, 'PASS', 'FAIL');
    run;

    title "Parity vs Python - max |SAS - Python| per metric (loose: tie-handling / asymptotic p)";
    proc print data=_cmsum noobs; var metric max_abs_diff tolv verdict; run;

    /* top-N: same segment at each rank?  by label, and by population (dev/mon counts) which is
       immune to the rounding difference in display labels */
    data _tops;
        merge _gt(keep=Segment_Definition Rank Dev_Count Mon_Count
                  rename=(Segment_Definition=g_def Rank=r Dev_Count=g_dc Mon_Count=g_mc))
              &sas_top(keep=Segment_Definition Rank Dev_Count Mon_Count
                  rename=(Segment_Definition=s_def Rank=r Dev_Count=s_dc Mon_Count=s_mc));
        by r;
        same_label = (g_def = s_def);
        same_pop   = (g_dc = s_dc and g_mc = s_mc);
    run;
    proc sql;
        select sum(same_label) as top_same_label, sum(same_pop) as top_same_population,
               count(*) as top_positions_compared from _tops;
    quit;
    title "Top-N by rank: Python vs SAS";
    proc print data=_tops noobs; var r g_def s_def g_dc s_dc g_mc s_mc same_label same_pop; run;
    title;

%mend seg_compare_to_golden;
