/* ============================================================================
   seg_trend_metrics.sas
   Step 2 of trend analysis - SAS port of core/multi_period_analysis.compute_trend_metrics.

   For every (Technique, Segment_Definition) that appeared in at least one period (history table
   from seg_trend_collect) it computes
     Frequency          = periods appeared / total periods
     Recency_Factor     = 0.5 ** (periods since last appearance / half_life)
     Consistency_Score  = longest run of consecutive periods appeared / total periods
     Trend_Impact_Score = w_freq*Frequency + w_rec*Recency + w_cons*Consistency   (rounded 4 dp)
     SIS_Trend          = SIS_Raw * (1 + trend_weight * Trend_Impact_Score)        (informational)
   then re-derives, WITHIN each technique's matched-segment set, the same root-cause blend
   as the single-period score (0.35 SIS + 0.30 DIS + 0.20 PSI + 0.15 SHAP, each min-max
   normalised) and boosts the whole blend once by persistence:
     Root_Cause_Score_Trend = min(1, blend * (1 + trend_weight * Trend_Impact_Score))
     Severity_Score_Trend   = Root_Cause_Score_Trend * 20
   The row kept for each segment is its MOST RECENT appearance (all columns), like Python.

   hist    : history table (Technique Segment_Definition Period Period_Index SIS_Raw DIS_Raw
             mean_feature_psi mean_shap_shift ...)
   periods : table with one row per analysed period (so periods with no appearances still count)
   out     : summary table, sorted by Technique then Severity_Score_Trend (descending)
   Parameters left blank take the sg_cfg_tr_* globals (run %seg_config first).
   ============================================================================ */
%macro seg_trend_metrics(hist=, periods=, out=, half_life=, w_freq=, w_rec=, w_cons=, trend_weight=);

    %local total;
    %if not %length(&half_life)    %then %let half_life    = &sg_cfg_tr_half_life;
    %if not %length(&w_freq)       %then %let w_freq       = &sg_cfg_tr_w_freq;
    %if not %length(&w_rec)        %then %let w_rec        = &sg_cfg_tr_w_rec;
    %if not %length(&w_cons)       %then %let w_cons       = &sg_cfg_tr_w_cons;
    %if not %length(&trend_weight) %then %let trend_weight = &sg_cfg_tr_weight;

    proc sql noprint; select count(*) into :total trimmed from &periods; quit;
    %if &total = 0 or %seg_nobs(&hist) = 0 %then %do;
        %put NOTE: seg_trend_metrics - no appearances to analyse.;
        data &out; length Technique $40 Segment_Definition $1000; stop; run;
        %return;
    %end;

    /* one row per (technique, segment, period), chronological */
    proc sort data=&hist out=_tr_h nodupkey; by Technique Segment_Definition Period_Index; run;

    data _tr_s;
        length Appeared_In $1000;
        set _tr_h; by Technique Segment_Definition;
        retain n_app last_prev run_cur run_max Appeared_In;
        if first.Segment_Definition then do;
            n_app = 0; run_cur = 0; run_max = 0; last_prev = .; Appeared_In = '';
        end;
        n_app + 1;
        if n_app = 1 then run_cur = 1;
        else if Period_Index = last_prev + 1 then run_cur = run_cur + 1;
        else run_cur = 1;
        run_max = max(run_max, run_cur);
        last_prev = Period_Index;
        Appeared_In = catx(', ', Appeared_In, Period);

        if last.Segment_Definition then do;
            SIS_Raw          = coalesce(SIS_Raw, 0);
            DIS_Raw          = coalesce(DIS_Raw, 0);
            mean_feature_psi = coalesce(mean_feature_psi, 0);
            mean_shap_shift  = coalesce(mean_shap_shift, 0);

            Periods_Appeared = n_app;
            Total_Periods    = &total;
            _freq  = n_app / &total;
            _rec   = 0.5 ** (((&total - 1) - Period_Index) / &half_life);
            _cons  = run_max / &total;
            _tis   = &w_freq * _freq + &w_rec * _rec + &w_cons * _cons;
            Frequency          = round(_freq, 0.0001);
            Recency_Factor     = round(_rec, 0.0001);
            Consistency_Score  = round(_cons, 0.0001);
            Trend_Impact_Score = round(_tis, 0.0001);
            SIS_Trend          = SIS_Raw * (1 + &trend_weight * _tis);
            output;
        end;
        drop n_app last_prev run_cur run_max _freq _rec _cons _tis Period Period_Index;
    run;

    /* normalise inside each technique's matched-segment set (all equal => 0) */
    proc sql;
        create table _tr_mm as
        select Technique,
               min(SIS_Raw) as s_lo format=best32., max(SIS_Raw) as s_hi format=best32.,
               min(DIS_Raw) as d_lo format=best32., max(DIS_Raw) as d_hi format=best32.,
               min(mean_feature_psi) as p_lo format=best32., max(mean_feature_psi) as p_hi format=best32.,
               min(mean_shap_shift) as h_lo format=best32., max(mean_shap_shift) as h_hi format=best32.
        from _tr_s group by Technique;
        create table _tr_n as
        select a.*, b.s_lo, b.s_hi, b.d_lo, b.d_hi, b.p_lo, b.p_hi, b.h_lo, b.h_hi
        from _tr_s a inner join _tr_mm b on a.Technique = b.Technique;
    quit;

    data &out;
        set _tr_n;
        if s_hi - s_lo < 1e-9 then _ns = 0; else _ns = (SIS_Raw - s_lo) / (s_hi - s_lo);
        if d_hi - d_lo < 1e-9 then _nd = 0; else _nd = (DIS_Raw - d_lo) / (d_hi - d_lo);
        if p_hi - p_lo < 1e-9 then _np = 0; else _np = (mean_feature_psi - p_lo) / (p_hi - p_lo);
        if h_hi - h_lo < 1e-9 then _nh = 0; else _nh = (mean_shap_shift - h_lo) / (h_hi - h_lo);
        _base = 0.35 * _ns + 0.30 * _nd + 0.20 * _np + 0.15 * _nh;
        Root_Cause_Score_Trend = min(1, _base * (1 + &trend_weight * Trend_Impact_Score));
        Severity_Score_Trend   = Root_Cause_Score_Trend * 20;
        drop s_lo s_hi d_lo d_hi p_lo p_hi h_lo h_hi _ns _nd _np _nh _base;
    run;
    proc sort data=&out; by Technique descending Severity_Score_Trend Segment_Definition; run;

%mend seg_trend_metrics;
