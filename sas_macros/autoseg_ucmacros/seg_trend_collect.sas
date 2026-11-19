/* ============================================================================
   seg_trend_collect.sas
   Step 1 of trend analysis (port of core/multi_period_analysis._build_period_appearance_long_df).

   After ONE period has been analysed (the technique <prefix>_segments tables exist), this macro
   adds that period's appearances to the history table: for every technique the worst
   n_worst segments by Severity_Score (Feature Binning's Overall_Score plays that role, as in
   seg_cross_technique), tagged with the period label and 0-based period index.
   Ties on Severity_Score are broken by the technique's own Rank.

   prefixes   : space-separated segment-table prefixes that ran OK (<p>_segments)
   period     : period label    period_idx : 0-based chronological position
   hist       : history table (created on first call, appended afterwards)
   ============================================================================ */
%macro seg_trend_collect(prefixes=, period=, period_idx=, n_worst=10, hist=seg_trend_history);

    %local n i p dsid hasos rc kp hl hm;

    %if not %sysfunc(exist(&hist)) %then %do;
        data &hist;
            length Technique $40 Segment_Definition $1000 Period $60 Root_Cause_Feature $64
                   Top_SHAP_Feature $64 Period_Index Rank 8
                   Dev_Count Mon_Count Dev_Pct Mon_Pct Dev_AUC Mon_AUC Dev_KS Mon_KS Dev_BR Mon_BR
                   Delta_AUC Delta_Gini Delta_KS Delta_BR PSI SIS_Raw DIS_Raw DIS_Symmetric
                   Root_Cause_Score Root_Cause_PSI Dev_EAD Mon_EAD Dev_Exposure_Pct Mon_Exposure_Pct
                   Exposure_Drift Top_SHAP_PSI mean_feature_psi mean_shap_shift Business_Impact_Score
                   Calibration_Drift Severity_Score Statistically_Significant 8;
            stop;
        run;
    %end;

    %if %index(&hist, .) %then %do;
        %let hl = %upcase(%scan(&hist, 1, .));
        %let hm = %upcase(%scan(&hist, 2, .));
    %end;
    %else %do;
        %let hl = WORK;
        %let hm = %upcase(&hist);
    %end;
    %let n = %sysfunc(countw(&prefixes, %str( )));
    %do i = 1 %to &n;
        %let p = %scan(&prefixes, &i, %str( ));
        %if %sysfunc(exist(&p._segments)) %then %do;
            %if %seg_nobs(&p._segments) > 0 %then %do;
                %let dsid  = %sysfunc(open(&p._segments));
                %let hasos = %sysfunc(varnum(&dsid, Overall_Score));
                %let rc    = %sysfunc(close(&dsid));

                data _tr_one;
                    set &p._segments;
                    %if &hasos > 0 %then %do;
                        Severity_Score = Overall_Score;
                        Statistically_Significant = Significant;
                    %end;
                    if not missing(Severity_Score);
                run;
                proc sort data=_tr_one; by Technique descending Severity_Score Rank; run;
                data _tr_one;
                    length Period $60;
                    set _tr_one; by Technique;
                    if first.Technique then _k = 0;
                    _k + 1;
                    if _k <= &n_worst;
                    Period = "&period";
                    Period_Index = &period_idx;
                    drop _k;
                run;
                /* keep only the variables the history table has, then concatenate (no append warnings) */
                proc sql noprint;
                    select a.name into :kp separated by ' '
                    from dictionary.columns a, dictionary.columns b
                    where a.libname = 'WORK' and a.memname = '_TR_ONE' and b.libname = "&hl" and b.memname = "&hm"
                      and upcase(a.name) = upcase(b.name);
                quit;
                data &hist; set &hist _tr_one(keep=&kp); run;
            %end;
        %end;
    %end;

%mend seg_trend_collect;
