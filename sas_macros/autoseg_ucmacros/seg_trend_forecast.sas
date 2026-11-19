/* ============================================================================
   seg_trend_forecast.sas
   Step 3 of trend analysis - SAS port of core/multi_period_analysis.forecast_segment_scores
   (early-warning forecast).

   For every (Technique, Segment_Definition) with at least 2 periods of history, fit the ordinary
   least-squares line  Root_Cause_Score = intercept + slope * Period_Index  (a segment with any
   missing score is skipped) and project one period ahead:
     Predicted_Next_Root_Cause_Score  clipped to [0, 1]
     Predicted_Next_Lower95/Upper95   95% prediction interval (needs >= 3 periods, clipped to [0, 1])
     Trend_Slope, R_Squared, Trend_P_Value (needs >= 3 periods; with 2 points they are missing)
     Months_To_Breach = whole periods until the line crosses the alert level (when the slope is
                        positive and the current score is below it), reported only if it is within
                        the horizon
     Early_Warning    = 1 when Months_To_Breach is reported, else 0
     Confidence       = "Low (2 points)" or "Medium (3+ points)"
   series  : history table (seg_trend_collect output) with Technique Segment_Definition Period
             Period_Index Root_Cause_Score
   out     : one row per forecastable segment, early warnings first
   Parameters left blank take sg_cfg_tr_alert / sg_cfg_tr_horizon (run %seg_config first).
   ============================================================================ */
%macro seg_trend_forecast(series=, out=, alert=, horizon=);

    %if not %length(&alert)   %then %let alert   = &sg_cfg_tr_alert;
    %if not %length(&horizon) %then %let horizon = &sg_cfg_tr_horizon;

    proc sort data=&series(keep=Technique Segment_Definition Period Period_Index Root_Cause_Score)
              out=_tf_s nodupkey;
        by Technique Segment_Definition Period_Index;
    run;

    data _tf_o;
        length Technique $40 Segment_Definition $1000 Last_Appeared_Period $60 Confidence $20;
        set _tf_s; by Technique Segment_Definition;
        retain cnt n sx sy sxx sxy syy bad;
        if first.Segment_Definition then do;
            cnt = 0; n = 0; sx = 0; sy = 0; sxx = 0; sxy = 0; syy = 0; bad = 0;
        end;
        cnt + 1;
        if missing(Root_Cause_Score) then bad = 1;
        else do;
            n + 1;
            sx  = sx  + Period_Index;
            sy  = sy  + Root_Cause_Score;
            sxx = sxx + Period_Index ** 2;
            sxy = sxy + Period_Index * Root_Cause_Score;
            syy = syy + Root_Cause_Score ** 2;
        end;

        if last.Segment_Definition and cnt >= 2 and bad = 0 then do;
            last_x  = Period_Index;
            last_y  = Root_Cause_Score;
            mx = sx / n;  my = sy / n;
            ssx = sxx - n * mx ** 2;
            ssxy = sxy - n * mx * my;
            ssy = syy - n * my ** 2;
            slope = ssxy / ssx;
            intercept = my - slope * mx;
            next_x = last_x + 1;
            predicted = min(1, max(0, slope * next_x + intercept));

            lower = .; upper = .; r2 = .; pval = .;
            if n >= 3 then do;
                dof = n - 2;
                sse = max(0, ssy - slope * ssxy);
                rse = sqrt(sse / dof);
                se_pred = rse * sqrt(1 + 1 / n + (next_x - mx) ** 2 / ssx);
                margin = tinv(0.975, dof) * se_pred;
                lower = min(1, max(0, predicted - margin));
                upper = min(1, max(0, predicted + margin));
                if ssy > 0 then r = ssxy / sqrt(ssx * ssy); else r = 0;
                if r > 1 then r = 1;
                if r < -1 then r = -1;
                r2 = r ** 2;
                if abs(r) >= 1 then pval = 0;
                else pval = 2 * (1 - probt(abs(r * sqrt(dof / ((1 - r) * (1 + r)))), dof));
            end;

            Months_To_Breach = .;
            Early_Warning = 0;
            if slope > 0 and last_y < &alert then do;
                m6 = round((((&alert - intercept) / slope) - last_x) * 1000000);
                if m6 > 0 then months_out = floor((m6 + 999999) / 1000000);
                else months_out = 0;
                if months_out > 0 and months_out <= &horizon then do;
                    Months_To_Breach = months_out;
                    Early_Warning = 1;
                end;
            end;

            Periods_Used = cnt;
            Last_Appeared_Period = Period;
            Current_Root_Cause_Score = round(last_y, 0.0001);
            Predicted_Next_Root_Cause_Score = round(predicted, 0.0001);
            Predicted_Next_Lower95 = round(lower, 0.0001);
            Predicted_Next_Upper95 = round(upper, 0.0001);
            Trend_Slope = round(slope, 0.00001);
            R_Squared = round(r2, 0.0001);
            Trend_P_Value = round(pval, 0.0001);
            if cnt = 2 then Confidence = 'Low (2 points)'; else Confidence = 'Medium (3+ points)';
            _mtb = coalesce(Months_To_Breach, 1e9);
            output;
        end;
        keep Technique Segment_Definition Periods_Used Last_Appeared_Period Current_Root_Cause_Score
             Predicted_Next_Root_Cause_Score Predicted_Next_Lower95 Predicted_Next_Upper95 Trend_Slope
             R_Squared Trend_P_Value Months_To_Breach Confidence Early_Warning _mtb;
    run;

    proc sort data=_tf_o out=&out(drop=_mtb);
        by descending Early_Warning _mtb Technique Segment_Definition;
    run;

%mend seg_trend_forecast;
