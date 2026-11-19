/* ============================================================================
   csb_segmentation_trend_wrapper.sas
   ENTRY POINT for MULTI-PERIOD TREND ANALYSIS (port of core/multi_period_analysis.py).

   The monitoring table holds several periods (a month / quarter / date column). For EACH period
   the whole segmentation module is run (development vs that period only), the worst segments of
   every technique are recorded, and the recurrence is then analysed:
     which segments keep coming back, how recently, how persistently  -> Trend_Impact_Score
     persistence-boosted root-cause score                             -> Severity_Score_Trend
     linear forecast of each segment's root-cause score               -> early warnings

   TRIGGER (minimum):
       %csb_segmentation_trend_wrapper(dev_dta=work.dev, mon_dta=work.mon_all_periods,
                                       period_col=month, target_col=default_flag);
     everything else is detected / defaulted exactly as in csb_segmentation_calc_wrapper
     (techniques=, exclude_cols= ... optional). Settings sg_cfg_tr_* (see seg_config.sas) can be
     overridden with %let before the call. Periods are analysed in ascending order of period_col
     (numeric, SAS date or text such as 2026-01 / 2026Q1 sort chronologically).

   OUTPUT tables (prefix = out_prefix, default segtr):
     <p>_summary     one row per recurring segment: Frequency, Recency_Factor, Consistency_Score,
                     Trend_Impact_Score, SIS_Trend, Root_Cause_Score_Trend, Severity_Score_Trend,
                     Periods_Appeared, Appeared_In, plus the segment's latest metrics
     <p>_series      month-by-month metrics of every recurring segment (one row per appearance)
     <p>_forecast    early-warning forecast per segment (slope, R-squared, p-value, interval,
                     Months_To_Breach, Early_Warning)
     <p>_cross_top10 cross-technique top 10 ranked on the trend-boosted scores (+ <p>_combined)
     <p>_history     every worst-N appearance recorded       <p>_periods  the periods analysed
     <p>_period_log  status and time of each period's run    <p>_metric_dictionary  column meanings
   RUN TIME: one full segmentation run per period (use sg_cfg_optimize=N and a technique subset
   while testing).
   ============================================================================ */
%macro seg_tr_pfx(t);
    %if &t = AUTOSLICER %then autoslicer;
    %else %if &t = DRIFT_TREE %then drifttree;
    %else %if &t = GRADIENT_BOOSTING %then gradboost;
    %else %if &t = KMEANS %then kmeans;
    %else %if &t = FEATURE_BINNING %then featbin;
%mend seg_tr_pfx;

%macro csb_segmentation_trend_wrapper(dev_dta=, mon_dta=, period_col=, target_col=, techniques=,
        score_col=, weight_col=, shap_cols=, feature_cols=, numeric_cols=, categorical_cols=,
        exclude_cols=, optimize=, top_n=, out_prefix=segtr);

    %local ptype np i j t t0 tl ntl pfxs pv nok pl tok st;

    %seg_config;

    %if not %length(&dev_dta) or not %length(&mon_dta) or not %length(&period_col) %then %do;
        %put ERROR: csb_segmentation_trend_wrapper - dev_dta= mon_dta= and period_col= are required.;
        %return;
    %end;
    %let ptype = %seg_vartype(ds=&mon_dta, var=&period_col);
    %if not %length(&ptype) %then %do;
        %put ERROR: csb_segmentation_trend_wrapper - period column &period_col not found in &mon_dta..;
        %return;
    %end;
    %if %length(&techniques) %then %let tl = %upcase(&techniques); %else %let tl = %upcase(&sg_cfg_techniques);
    %let ntl = %sysfunc(countw(&tl, %str( )));

    /* ---- periods, chronological ---- */
    proc sql;
        create table &out_prefix._periods as
        select distinct &period_col as pval from &mon_dta where not missing(&period_col)
        order by &period_col;
    quit;
    %let np = 0;
    data &out_prefix._periods;
        length Period $60;
        set &out_prefix._periods;
        Period_Index = _n_ - 1;
        Period = strip(vvalue(pval));
        %if &ptype = N %then %do; call symputx(cats('trv', _n_), strip(put(pval, best32.)), 'L'); %end;
        %else %do;             call symputx(cats('trv', _n_), strip(pval), 'L'); %end;
        call symputx('np', _n_, 'L');
    run;
    %if &np < 2 %then %do;
        %put ERROR: csb_segmentation_trend_wrapper - trend analysis needs at least 2 periods in &period_col (found &np).;
        %return;
    %end;
    %put NOTE: csb_segmentation_trend_wrapper - &np periods will be analysed.;

    proc datasets lib=work nolist nowarn; delete &out_prefix._history &out_prefix._period_log; quit;
    data &out_prefix._period_log;
        length Period $60 Period_Index 8 Status $12 Techniques_OK 8 Seconds 8;
        stop;
    run;

    /* ---- one full segmentation run per period ---- */
    %do i = 1 %to &np;
        %let t0 = %sysfunc(datetime());
        %let pv = &&trv&i;
        proc sql noprint; select Period into :pl trimmed from &out_prefix._periods where Period_Index = %eval(&i - 1); quit;

        proc datasets lib=work nolist nowarn; delete _sgp_: ; quit;
        data work._sgp_mon;
            set &mon_dta;
            %if &ptype = N %then %do; where &period_col = &pv; %end;
            %else %do;             where &period_col = "&pv"; %end;
        run;

        %let syscc = 0;
        %csb_segmentation_calc_wrapper(dev_dta=&dev_dta, mon_dta=work._sgp_mon, target_col=&target_col,
            techniques=&techniques, score_col=&score_col, weight_col=&weight_col, shap_cols=&shap_cols,
            feature_cols=&feature_cols, numeric_cols=&numeric_cols, categorical_cols=&categorical_cols,
            exclude_cols=&exclude_cols &period_col, optimize=&optimize, top_n=&top_n, out_prefix=_sgp);

        /* techniques of this period that finished OK */
        %let pfxs = ;
        %let nok = 0;
        %do j = 1 %to &ntl;
            %let t = %scan(&tl, &j, %str( ));
            %if %sysfunc(exist(_sgp_run_log)) %then %do;
                proc sql noprint;
                    select count(*) into :tok trimmed from _sgp_run_log where upcase(technique) = "&t" and status = "OK";
                quit;
                %if &tok > 0 %then %do;
                    %let pfxs = &pfxs _sgp_%seg_tr_pfx(&t);
                    %let nok = %eval(&nok + 1);
                %end;
            %end;
        %end;

        %if &nok > 0 %then %do;
            %seg_trend_collect(prefixes=&pfxs, period=&pl, period_idx=%eval(&i - 1),
                               n_worst=&sg_cfg_tr_n_worst, hist=&out_prefix._history);
        %end;
        %let st = OK;
        %if &nok = 0 %then %let st = NO_RESULT;
        proc sql;
            insert into &out_prefix._period_log
            values("&pl", %eval(&i - 1), "&st", &nok,
                   %sysevalf(%sysfunc(datetime()) - &t0));
        quit;
    %end;

    /* ---- trend metrics, series, forecast ---- */
    %if not %sysfunc(exist(&out_prefix._history)) %then %do;
        %put ERROR: csb_segmentation_trend_wrapper - no period produced any segments.;
        %return;
    %end;
    %seg_trend_metrics(hist=&out_prefix._history, periods=&out_prefix._periods, out=&out_prefix._summary);
    proc sort data=&out_prefix._history out=&out_prefix._series;
        by Technique Segment_Definition Period_Index;
    run;
    %seg_trend_forecast(series=&out_prefix._history, out=&out_prefix._forecast);

    /* ---- cross-technique ranking on the trend-boosted scores (as the Streamlit trend path:
           Severity_Score_Trend / Root_Cause_Score_Trend replace Severity_Score / Root_Cause_Score) ---- */
    %if %seg_nobs(&out_prefix._summary) > 0 %then %do;
        data &out_prefix._trendseg_segments;
            set &out_prefix._summary;
            Severity_Score   = Severity_Score_Trend;
            Root_Cause_Score = Root_Cause_Score_Trend;
        run;
        %seg_cross_technique(prefixes=&out_prefix._trendseg, out_prefix=&out_prefix);
        proc datasets lib=work nolist nowarn; delete &out_prefix._trendseg_segments; quit;
    %end;

    /* ---- explainability ---- */
    %seg_metric_dictionary(out=&out_prefix._metric_dictionary);
    %seg_apply_labels(prefix=&out_prefix, dict=&out_prefix._metric_dictionary);

    %put NOTE: csb_segmentation_trend_wrapper complete - see &out_prefix._summary and &out_prefix._forecast;

%mend csb_segmentation_trend_wrapper;
