/* ============================================================================
   csb_rm_kpi_segmentation.sas
   ADAPTER between SAS Risk Modeling KPI calculation code and the segmentation (RCA) module.

   Every RCA KPI in Risk Modeling has a tiny Code tab that calls this macro with its own KPI id
   (the KPI ID on the KPI's Details tab) and the metric to calculate:
       %csb_rm_kpi_segmentation(kpi_id=rca_max_gini_drop, metric=rca_max_gini_drop);
   If Risk Modeling assigned a numeric id (for example 10000):
       %csb_rm_kpi_segmentation(kpi_id=10000, metric=rca_max_gini_drop);
   The macro
     1. reads the SCORED data set that Risk Modeling provides for this run
        (&m_scored_ds_libref_kpi_calc..&m_scored_ds_nm_kpi_calc) = the MONITORING data
        (input variables + target &m_act_result_col_name + score &m_est_result_col_name)
     2. development run (m_run_type_cd = DD): saves that data as the DEVELOPMENT REFERENCE
        (rcadev_<model id>.csv in &sg_rm_ref_folder, or data set &sg_rm_ref_libref..rcadev_<model id>)
        and returns; ongoing / backtesting run (ONG / BCK): reads the reference
     3. runs the segmentation module (development vs monitoring, fixed parameters, chosen techniques)
     4. turns the result into ONE number for this KPI and inserts it
        (KPI_ID, KPI_VALUE) into &m_output_cas_libref..&m_kpi_value_otpt_cas_tbl_nm
     5. sets m_kpi_calc_success_flg to Y or N (N = the KPI could not be calculated)

   KPIs (id -> value; all LOWER = healthier; only STATISTICALLY SIGNIFICANT segments count):
     rca_max_gini_drop        largest Gini drop of any segment      max(0, Dev_Gini - Mon_Gini)
     rca_max_ks_drop          largest KS drop of any segment
     rca_max_badrate_rise     largest bad-rate rise of any segment (absolute, 0.05 = 5 points)
     rca_max_segment_psi      largest segment-size PSI of any segment
     rca_n_deteriorating      number of significant segments whose Gini fell
   Impact KPIs (the module's own derived scores; raw values, so comparable between runs):
     rca_max_sis              largest SIS_Raw  = AUC drop x exposure x population share x confidence
     rca_max_dis              largest DIS_Raw  = population shift x AUC drop x exposure x (1 + mean feature PSI)
     rca_max_business_impact  largest Business_Impact_Score = population x exposure x (1 + PSI + Gini drop)
     rca_max_portfolio_impact largest Portfolio_Impact_Score = population share x |Gini change|
     rca_n_significant        number of statistically significant segments
   More single-comparison KPIs (raw, comparable between runs):
     rca_max_feature_drift    largest mean_feature_psi (average feature drift inside a segment)
     rca_max_shap_shift       largest mean_shap_shift (needs SHAP columns in the data)
     rca_max_exposure_drift   largest |Exposure_Drift| (exposure share change)
     rca_max_calibration_drift largest |Calibration_Drift| (actual/expected default ratio shift)
     rca_max_ece_rise         largest Delta_ECE (Feature Binning only)
   TREND KPIs (a run per period, so they need %let sg_rm_period_col = <period column of the scored data>):
     rca_max_trend_impact     largest Trend_Impact_Score (frequency / recency / consistency of a segment)
     rca_n_early_warning      segments projected to cross the alert level within the horizon
     rca_max_trend_slope      steepest rising Root_Cause_Score slope (per period)
     rca_min_months_to_breach fewest periods until a breach (HIGHER = healthier; horizon if none flagged)
   (Root_Cause_Score, Severity_Score, Deterioration_Score and Overall_Score are NOT KPIs: they are
    min-max normalised inside each run, so they cannot be compared between runs.)

   The KPI code (see RM_INTEGRATION_KPIS.md) first compiles the macros at top level, then sets
       %let sg_rm_ref_folder = <SAS Content folder for the development reference file (CSV)>;
         (or %let sg_rm_ref_libref = <writable PERSISTENT library>;)
       %let sg_rm_bootstrap = <optional Y: with no reference yet, the first run becomes the baseline>;
       %let sg_rm_exclude_cols = <optional: space-separated columns the module must not use>;
       %let sg_rm_target_col / sg_rm_score_col = <optional: names of the 0/1 target and the score column>;
   and calls this macro. (The macros are compiled OUTSIDE this macro on purpose.)
   Local macro variables only (RM rule): nothing is declared global here except the module's own
   sg_* settings, whose names cannot collide with RM statistic macros.
   ============================================================================ */
%macro csb_rm_kpi_segmentation(kpi_id=, metric=, techniques=DRIFT_TREE FEATURE_BINNING);

    %local rn cv ln nbad nok pcol tname autox colnames ref_ds tcol scol xcols v_gd v_kd v_br v_psi v_n
           v_sis v_dis v_bi v_pf v_ns v_fd v_sh v_ex v_cd v_ece v_tis v_ew v_slope v_mtb istr pcolx val ok refmode boot have;
    %let ok = 1;
    %if not %length(&metric) %then %let metric = &kpi_id;      /* kpi_id = the id Risk Modeling gave the KPI, metric = what to calculate */
    %let v_gd = 0; %let v_kd = 0; %let v_br = 0; %let v_psi = 0; %let v_n = 0;
    %let v_sis = 0; %let v_dis = 0; %let v_bi = 0; %let v_pf = 0; %let v_ns = 0;
    %let v_fd = 0; %let v_sh = 0; %let v_ex = 0; %let v_cd = 0; %let v_ece = 0;
    %let v_tis = 0; %let v_ew = 0; %let v_slope = 0; %let v_mtb = 0;
    /* the trend KPIs need a multi-period run (trend=Y); all the others are a single comparison */
    %let istr = 0;
    %if %sysfunc(indexw(rca_max_trend_impact rca_n_early_warning rca_max_trend_slope rca_min_months_to_breach, %lowcase(&metric))) %then %let istr = 1;

    /* where the development reference lives: a SAS Content folder (sg_rm_ref_folder, preferred - a CSV file)
       or a persistent library (sg_rm_ref_libref - a data set) */
    %let refmode = ;
    %if %symexist(sg_rm_ref_folder) %then %do;
        %if %length(&sg_rm_ref_folder) %then %let refmode = FOLDER;
    %end;
    %if not %length(&refmode) and %symexist(sg_rm_ref_libref) %then %do;
        %if %length(&sg_rm_ref_libref) %then %let refmode = LIB;
    %end;
    %if not %length(&refmode) %then %do;
        %put ERROR: csb_rm_kpi_segmentation - set sg_rm_ref_folder (SAS Content folder) or sg_rm_ref_libref before the call.;
        %let m_kpi_calc_success_flg = N;
        %return;
    %end;
    %let boot = N;
    %if %symexist(sg_rm_bootstrap) %then %let boot = %upcase(%substr(&sg_rm_bootstrap.N, 1, 1));
    %if not %sysmacexist(csb_segmentation_run) %then %do;
        %put ERROR: csb_rm_kpi_segmentation - compile the segmentation macros first (seg_compile_viya.sas).;
        %let m_kpi_calc_success_flg = N;
        %return;
    %end;
    %let xcols = ;
    %if %symexist(sg_rm_exclude_cols) %then %let xcols = &sg_rm_exclude_cols;

    /* ---- 1. monitoring data of this run (copied to WORK; works for SAS and CAS librefs) ---- */
    data work.rm_mon;
        set &m_scored_ds_libref_kpi_calc..&m_scored_ds_nm_kpi_calc;
    run;
    /* target and score column: explicit override (sg_rm_target_col / sg_rm_score_col) > the Risk Modeling macro
       variables (empty or a dot for some model types, e.g. scorecards) > blank = automatic detection by the module */
    %let tcol = ;
    %let scol = ;
    %if %symexist(sg_rm_target_col) %then %let tcol = &sg_rm_target_col;
    %if not %length(&tcol) and %symexist(m_act_result_col_name) %then %let tcol = &m_act_result_col_name;
    %if "&tcol" = "." %then %let tcol = ;
    %if %symexist(sg_rm_score_col) %then %let scol = &sg_rm_score_col;
    %if not %length(&scol) and %symexist(m_est_result_col_name) %then %let scol = &m_est_result_col_name;
    %if "&scol" = "." %then %let scol = ;
    /* write the column list to the log so the right names can be found */
    %let colnames = ;
    proc sql noprint;
        select name into :colnames separated by ' ' from dictionary.columns
        where libname = 'WORK' and memname = 'RM_MON' order by varnum;
    quit;
    %put NOTE: csb_rm_kpi_segmentation - target=[&tcol] score=[&scol] columns of the scored data set: &colnames;
    %if %length(&scol) %then %do;
        %if not %length(%seg_vartype(ds=work.rm_mon, var=&scol)) %then %let scol = ;
    %end;
    /* SAS scoring convention: the score is P_<target>1 and the outcome is <target> (for example P_REJECT_FLG1 and REJECT_FLG) */
    %let pcol = ;
    proc sql noprint;
        select name into :pcol trimmed from dictionary.columns
        where libname = 'WORK' and memname = 'RM_MON' and prxmatch('/^P_.+1$/i', strip(name)) > 0
        order by varnum;
    quit;
    %if not %length(&scol) and %length(&pcol) %then %let scol = &pcol;
    %if not %length(&tcol) and %length(&pcol) %then %do;
        %let tname = %sysfunc(prxchange(s/^P_(.+)1$/$1/i, 1, &pcol));
        %if %length(%seg_vartype(ds=work.rm_mon, var=&tname)) %then %let tcol = &tname;
    %end;
    %if %length(&tcol) %then %do;
        %if not %length(%seg_vartype(ds=work.rm_mon, var=&tcol)) %then %do;
            %put ERROR: csb_rm_kpi_segmentation - target column &tcol not found in the scored data set - set sg_rm_target_col.;
            %let m_kpi_calc_success_flg = N;
            %return;
        %end;
    %end;
    /* scoring artefacts that must never be used as segmentation features: scorecard group / points columns
       (GRP_*, SCR_*, EM_*), SCORECARD_POINTS, SCORE_POINTS and the decision column OUTCOME_CD */
    %let autox = ;
    proc sql noprint;
        select name into :autox separated by ' ' from dictionary.columns
        where libname = 'WORK' and memname = 'RM_MON'
          and (prxmatch('/^(GRP|SCR|EM)_/i', strip(name)) > 0
               or upcase(strip(name)) in ('SCORECARD_POINTS', 'SCORE_POINTS', 'OUTCOME_CD'));
    quit;
    %let xcols = &xcols &autox;
    %put NOTE: csb_rm_kpi_segmentation - target=[&tcol] score=[&scol] automatically excluded columns: &autox;
    /* the target and the score must be numeric: convert them if the scored data set stores them as text */
    %if %length(&scol) %then %do;
        %if %seg_vartype(ds=work.rm_mon, var=&scol) = C %then %do;
            data work.rm_mon(drop=&scol rename=(_cv=&scol)); set work.rm_mon; _cv = input(&scol, ?? best32.); run;
        %end;
    %end;
    %if %length(&tcol) %then %do;
        %if %seg_vartype(ds=work.rm_mon, var=&tcol) = C %then %do;
            data work.rm_mon(drop=&tcol rename=(_cv=&tcol)); set work.rm_mon; _cv = input(&tcol, ?? best32.); run;
        %end;
    %end;

    /* ---- 2. development reference ---- */
    %let ref_ds = ;
    %if &refmode = LIB %then %let ref_ds = &sg_rm_ref_libref..rcadev_&m_model_id;
    %if &refmode = FOLDER %then %do;
        filename rcaref filesrvc folderpath="&sg_rm_ref_folder" filename="rcadev_&m_model_id..csv";
    %end;

    /* development run: save this data as the reference and stop */
    %if %upcase(&m_run_type_cd) = DD %then %do;
        %if &refmode = FOLDER %then %do;
            proc export data=work.rm_mon outfile=rcaref dbms=csv replace; run;
        %end;
        %else %do;
            data &ref_ds; set work.rm_mon; run;
        %end;
        %put NOTE: csb_rm_kpi_segmentation - development reference saved for model &m_model_id;
        %let m_kpi_calc_success_flg = Y;
        %return;
    %end;

    /* ongoing / backtesting run: is there a reference? */
    %let have = 0;
    %if &refmode = FOLDER %then %do;
        %if %sysfunc(fexist(rcaref)) %then %let have = 1;
    %end;
    %else %do;
        %if %sysfunc(exist(&ref_ds)) %then %let have = 1;
    %end;
    %if not &have %then %do;
        %if &boot = Y %then %do;
            /* sg_rm_bootstrap=Y: the FIRST run becomes the baseline period (compared with itself, so the KPI is 0) */
            %put NOTE: csb_rm_kpi_segmentation - no development reference for model &m_model_id - this run becomes the baseline (KPI value 0).;
            %if &refmode = FOLDER %then %do;
                proc export data=work.rm_mon outfile=rcaref dbms=csv replace; run;
            %end;
            %else %do;
                data &ref_ds; set work.rm_mon; run;
            %end;
        %end;
        %else %do;
            %put ERROR: csb_rm_kpi_segmentation - no development reference for model &m_model_id - run the development (DD) calculation first, or set sg_rm_bootstrap=Y to use this run as the baseline.;
            %let m_kpi_calc_success_flg = N;
            %return;
        %end;
    %end;
    %if &refmode = FOLDER %then %do;
        proc import datafile=rcaref out=work.rm_dev dbms=csv replace; getnames=yes; guessingrows=max; run;
    %end;
    %else %do;
        data work.rm_dev; set &ref_ds; run;
    %end;

    /* the reference was saved as CSV, so PROC IMPORT guessed its column types again: make every column of the
       reference the same type (and character length) as in the current data, otherwise the module stops */
    proc sql noprint;
        create table work._rm_ty as
        select upcase(m.name) as nm, m.name as mname, m.type as tm, m.length as lm, d.name as dname, d.type as td
        from dictionary.columns m inner join dictionary.columns d on upcase(m.name) = upcase(d.name)
        where m.libname = 'WORK' and m.memname = 'RM_MON' and d.libname = 'WORK' and d.memname = 'RM_DEV'
          and m.type ne d.type;
    quit;
    %let rn = ;
    %let cv = ;
    %let ln = ;
    data _null_;
        set work._rm_ty end=_e;
        length r c l $4000;
        retain r c l '';
        t = cats('_t', _n_);
        r = catx(' ', r, cats(dname, '=', t));
        if tm = 'num' then c = catx(' ', c, cats(dname, '=input(', t, ', ?? best32.);'));
        else do;
            c = catx(' ', c, cats(dname, '=strip(put(', t, ', best32.));'));
            l = catx(' ', l, cats('length ', dname, ' $', max(lm, 32), ';'));
        end;
        if _e then do;
            call symputx('rn', r, 'L'); call symputx('cv', c, 'L'); call symputx('ln', l, 'L');
        end;
    run;
    %if %length(&rn) %then %do;
        %put NOTE: csb_rm_kpi_segmentation - aligning column types of the reference with the current data: &rn;
        data work.rm_dev;
            &ln
            set work.rm_dev(rename=(&rn));
            &cv
            drop _t:;
        run;
    %end;

    /* ---- 3T. TREND KPIs: one run per period of the monitoring data (needs sg_rm_period_col) ---- */
    %if &istr %then %do;
        %let pcolx = ;
        %if %symexist(sg_rm_period_col) %then %let pcolx = &sg_rm_period_col;
        %if not %length(&pcolx) %then %do;
            %put ERROR: csb_rm_kpi_segmentation - the trend KPI &metric needs %nrstr(%let) sg_rm_period_col = <period column of the scored data set> (a column with the month or quarter).;
            %let m_kpi_calc_success_flg = N;
            %return;
        %end;
        %if not %length(%seg_vartype(ds=work.rm_mon, var=&pcolx)) %then %do;
            %put ERROR: csb_rm_kpi_segmentation - period column &pcolx not found in the scored data set.;
            %let m_kpi_calc_success_flg = N;
            %return;
        %end;
        %let syscc = 0;
        %csb_segmentation_run(dev_dta=work.rm_dev, mon_dta=work.rm_mon, target_col=&tcol, score_col=&scol,
                              trend=Y, period_col=&pcolx, techniques=&techniques, optimize=N,
                              exclude_cols=&xcols, out_prefix=rmseg);
        %let nbad = 0;
        %let nok = 0;
        %if %sysfunc(exist(rmseg_period_log)) %then %do;
            proc sql noprint;
                select count(*) into :nbad trimmed from rmseg_period_log where Status ne 'OK';
                select count(*) into :nok  trimmed from rmseg_period_log where Status = 'OK';
            quit;
        %end;
        %if &nok = 0 or &nbad > 0 or not %sysfunc(exist(rmseg_summary)) or not %sysfunc(exist(rmseg_forecast)) %then %do;
            %put ERROR: csb_rm_kpi_segmentation - the trend run did not finish cleanly (periods OK: &nok - failed: &nbad) - see rmseg_period_log and the log above.;
            %let m_kpi_calc_success_flg = N;
            %return;
        %end;
        %let v_mtb = &sg_cfg_tr_horizon;               /* no segment flagged = no breach within the horizon */
        data _null_;
            set rmseg_summary end=_e;
            retain a_tis 0;
            if not missing(Trend_Impact_Score) then a_tis = max(a_tis, Trend_Impact_Score);
            if _e then call symputx('v_tis', put(a_tis, best32.), 'L');
        run;
        data _null_;
            set rmseg_forecast end=_e;
            retain a_ew 0 a_sl 0 a_mb .;
            if Early_Warning = 1 then do;
                a_ew = a_ew + 1;
                if not missing(Months_To_Breach) then do;
                    if missing(a_mb) then a_mb = Months_To_Breach; else a_mb = min(a_mb, Months_To_Breach);
                end;
            end;
            if not missing(Trend_Slope) then a_sl = max(a_sl, Trend_Slope);
            if _e then do;
                call symputx('v_ew', put(a_ew, best32.), 'L');
                call symputx('v_slope', put(a_sl, best32.), 'L');
                if not missing(a_mb) then call symputx('v_mtb', put(a_mb, best32.), 'L');
            end;
        run;
        %let val = ;
        %if %lowcase(&metric) = rca_max_trend_impact       %then %let val = &v_tis;
        %else %if %lowcase(&metric) = rca_n_early_warning  %then %let val = &v_ew;
        %else %if %lowcase(&metric) = rca_max_trend_slope  %then %let val = &v_slope;
        %else %if %lowcase(&metric) = rca_min_months_to_breach %then %let val = &v_mtb;
    %end;
    %else %do;

    /* ---- 3. run the module (fixed parameters, chosen techniques, no trend) ---- */
    %let syscc = 0;
    %csb_segmentation_run(dev_dta=work.rm_dev, mon_dta=work.rm_mon, target_col=&tcol, score_col=&scol,
                          trend=N, techniques=&techniques, optimize=N, exclude_cols=&xcols, out_prefix=rmseg);
    /* a technique that stopped with errors must not be reported as a healthy 0 */
    %let nbad = 0;
    %let nok = 0;
    %if %sysfunc(exist(rmseg_run_log)) %then %do;
        proc sql noprint;
            select count(*) into :nbad trimmed from rmseg_run_log where status ne 'OK';
            select count(*) into :nok trimmed from rmseg_run_log where status = 'OK';
        quit;
    %end;
    %if &nok = 0 or &nbad > 0 %then %do;
        %put ERROR: csb_rm_kpi_segmentation - the segmentation run did not finish cleanly (techniques OK: &nok - failed: &nbad) - see rmseg_run_log and the log above.;
        %let m_kpi_calc_success_flg = N;
        %return;
    %end;
    %if not %sysfunc(exist(rmseg_combined)) %then %do;
        %put ERROR: csb_rm_kpi_segmentation - the segmentation run produced no result table.;
        %let m_kpi_calc_success_flg = N;
        %return;
    %end;

    /* ---- 4. one number per KPI from the significant segments ---- */
    data _null_;
        set rmseg_combined end=_e;
        retain a_gd 0 a_kd 0 a_br 0 a_psi 0 a_nn 0 a_sis 0 a_dis 0 a_bi 0 a_pf 0 a_ns 0
               a_fd 0 a_sh 0 a_ex 0 a_cd 0 a_ece 0;
        if Statistically_Significant = 1 then do;
            a_ns = a_ns + 1;
            if not missing(mean_feature_psi) then a_fd  = max(a_fd, mean_feature_psi);
            if not missing(mean_shap_shift)  then a_sh  = max(a_sh, mean_shap_shift);
            if not missing(Exposure_Drift)   then a_ex  = max(a_ex, abs(Exposure_Drift));
            if not missing(Calibration_Drift) then a_cd = max(a_cd, abs(Calibration_Drift));
            if not missing(Delta_ECE)        then a_ece = max(a_ece, Delta_ECE);
            if not missing(SIS_Raw)                then a_sis = max(a_sis, SIS_Raw);
            if not missing(DIS_Raw)                then a_dis = max(a_dis, DIS_Raw);
            if not missing(Business_Impact_Score)  then a_bi  = max(a_bi, Business_Impact_Score);
            if not missing(Portfolio_Impact_Score) then a_pf  = max(a_pf, Portfolio_Impact_Score);
            if not missing(Delta_Gini) then a_gd = max(a_gd, -Delta_Gini);
            if not missing(Delta_KS)   then a_kd = max(a_kd, -Delta_KS);
            if not missing(Delta_BR)   then a_br = max(a_br, Delta_BR);
            if not missing(PSI)        then a_psi = max(a_psi, PSI);
            if not missing(Delta_Gini) and Delta_Gini < 0 then a_nn = a_nn + 1;
        end;
        if _e then do;
            call symputx('v_gd', put(a_gd, best32.), 'L');
            call symputx('v_kd', put(a_kd, best32.), 'L');
            call symputx('v_br', put(a_br, best32.), 'L');
            call symputx('v_psi', put(a_psi, best32.), 'L');
            call symputx('v_n', put(a_nn, best32.), 'L');
            call symputx('v_sis', put(a_sis, best32.), 'L');
            call symputx('v_dis', put(a_dis, best32.), 'L');
            call symputx('v_bi',  put(a_bi,  best32.), 'L');
            call symputx('v_pf',  put(a_pf,  best32.), 'L');
            call symputx('v_ns',  put(a_ns,  best32.), 'L');
            call symputx('v_fd',  put(a_fd,  best32.), 'L');
            call symputx('v_sh',  put(a_sh,  best32.), 'L');
            call symputx('v_ex',  put(a_ex,  best32.), 'L');
            call symputx('v_cd',  put(a_cd,  best32.), 'L');
            call symputx('v_ece', put(a_ece, best32.), 'L');
        end;
    run;

    %let val = ;
    %if %lowcase(&metric) = rca_max_gini_drop      %then %let val = &v_gd;
    %else %if %lowcase(&metric) = rca_max_ks_drop        %then %let val = &v_kd;
    %else %if %lowcase(&metric) = rca_max_badrate_rise   %then %let val = &v_br;
    %else %if %lowcase(&metric) = rca_max_segment_psi    %then %let val = &v_psi;
    %else %if %lowcase(&metric) = rca_n_deteriorating    %then %let val = &v_n;
    %else %if %lowcase(&metric) = rca_max_sis            %then %let val = &v_sis;
    %else %if %lowcase(&metric) = rca_max_dis            %then %let val = &v_dis;
    %else %if %lowcase(&metric) = rca_max_business_impact %then %let val = &v_bi;
    %else %if %lowcase(&metric) = rca_max_portfolio_impact %then %let val = &v_pf;
    %else %if %lowcase(&metric) = rca_n_significant      %then %let val = &v_ns;
    %else %if %lowcase(&metric) = rca_max_feature_drift  %then %let val = &v_fd;
    %else %if %lowcase(&metric) = rca_max_shap_shift     %then %let val = &v_sh;
    %else %if %lowcase(&metric) = rca_max_exposure_drift %then %let val = &v_ex;
    %else %if %lowcase(&metric) = rca_max_calibration_drift %then %let val = &v_cd;
    %else %if %lowcase(&metric) = rca_max_ece_rise       %then %let val = &v_ece;
    %end;   /* end of the single-comparison branch */
    %if not %length(&val) %then %do;
        %put ERROR: csb_rm_kpi_segmentation - unknown metric &metric..;
        %let m_kpi_calc_success_flg = N;
        %return;
    %end;

    /* ---- 5. insert into the Risk Modeling KPI output table + error handling ---- */
    proc sql noprint;
        insert into &m_output_cas_libref..&m_kpi_value_otpt_cas_tbl_nm.(KPI_ID, KPI_VALUE)
        values("&kpi_id", &val);
    quit;
    %if &syserr. gt 4 %then %let m_kpi_calc_success_flg = N;
    %else %let m_kpi_calc_success_flg = Y;
    %put NOTE: csb_rm_kpi_segmentation - &kpi_id = &val (success flag &m_kpi_calc_success_flg);

%mend csb_rm_kpi_segmentation;
