/* ============================================================================
   seg_viz_prepare_trend.sas
   Chart-ready tables for the TREND charts of the Python project (utils/charts.py):
     segment_all_metrics_chart / segment_metric_time_series_chart (metrics over time + forecast point)
     early_warning_urgency_chart (most urgent early-warning segments).

   series   : <p>_series (trend run): Technique, Segment_Definition, Period, Period_Index,
              Mon_Pct, Mon_AUC, Mon_BR, Root_Cause_Score (one row per appearance)
   periods  : <p>_periods (Period_Index, Period) - ALL periods analysed, so a month in which a segment
              was not among the worst N is a real GAP in the line (as in the Python reindex)
   forecast : <p>_forecast (seg_trend_forecast output); optional
   out      : prefix of the tables written (default viz)
   n_early  : number of early-warning segments kept (Python default 10)

   OUTPUT (WORK data sets)
     <out>_timeseries  long: Segment_No, Segment_Key, Technique, Segment_Definition, Period, Period_Index,
                       Metric (Population Pct, AUC, Bad Rate, Root Cause Score, Root Cause Score (forecast)),
                       Value (missing = the segment was not in the worst N that month).
                       The forecast metric has two points per segment: the last actual month and
                       "Next month (forecast)".
     <out>_early_warning  Rank, Label, Months_To_Breach, Confidence, Segment_Definition, Technique
                       (Early_Warning = 1 rows, fewest months first)
   ============================================================================ */
%macro seg_viz_prepare_trend(series=, periods=, forecast=, out=viz, n_early=10);

    %local np;
    %if not %sysfunc(exist(&series)) or not %sysfunc(exist(&periods)) %then %do;
        %put ERROR: seg_viz_prepare_trend - series= and periods= tables are required.;
        %return;
    %end;
    %let np = %seg_nobs(&periods);

    /* every (technique, segment) x every period; metrics joined on (segment, period) */
    proc sql;
        create table _vt_seg as
        select distinct Technique, Segment_Definition from &series order by Technique, Segment_Definition;
    quit;
    data _vt_seg; set _vt_seg; Segment_No = _n_; run;
    proc sql;
        create table _vt_full as
        select s.Segment_No, s.Technique, s.Segment_Definition, p.Period, p.Period_Index,
               a.Mon_Pct, a.Mon_AUC, a.Mon_BR, a.Root_Cause_Score
        from _vt_seg s
             inner join &periods p on 1 = 1
             left join &series a on a.Technique = s.Technique and a.Segment_Definition = s.Segment_Definition
                                and a.Period_Index = p.Period_Index
        order by s.Segment_No, p.Period_Index;
    quit;

    /* long format: one row per segment x period x metric */
    data &out._timeseries;
        set _vt_full;
        length Segment_Key $120 Metric $40;
        Segment_Key = catx(': ', Technique, substr(strip(Segment_Definition), 1, 80));
        Metric = 'Population Pct';        Value = Mon_Pct;           output;
        Metric = 'AUC';                 Value = Mon_AUC;           output;
        Metric = 'Bad Rate';            Value = Mon_BR;            output;
        Metric = 'Root Cause Score';    Value = Root_Cause_Score;  output;
        keep Segment_No Segment_Key Technique Segment_Definition Period Period_Index Metric Value;
    run;

    /* forecast: dashed line from the last actual value to the predicted next value */
    %if %length(&forecast) %then %do;
        %if %sysfunc(exist(&forecast)) %then %do;
            %if %seg_nobs(&forecast) > 0 %then %do;
                proc sql;
                    create table _vt_fc as
                    select s.Segment_No, s.Technique, s.Segment_Definition, f.Last_Appeared_Period,
                           f.Current_Root_Cause_Score, f.Predicted_Next_Root_Cause_Score
                    from &forecast f inner join _vt_seg s
                         on s.Technique = f.Technique and s.Segment_Definition = f.Segment_Definition;
                quit;
                data _vt_fc2;
                    set _vt_fc;
                    length Segment_Key $120 Metric $40 Period $60;
                    Segment_Key = catx(': ', Technique, substr(strip(Segment_Definition), 1, 80));
                    Metric = 'Root Cause Score (forecast)';
                    Period = Last_Appeared_Period;           Period_Index = .;  Value = Current_Root_Cause_Score;           output;
                    Period = 'Next month (forecast)';        Period_Index = &np; Value = Predicted_Next_Root_Cause_Score;   output;
                    keep Segment_No Segment_Key Technique Segment_Definition Period Period_Index Metric Value;
                run;
                /* the first forecast point sits on the last actual month: give it that month's index */
                proc sql;
                    update _vt_fc2 f set Period_Index =
                        (select p.Period_Index from &periods p where strip(p.Period) = strip(f.Period))
                        where missing(f.Period_Index);
                quit;
                data &out._timeseries;
                    set &out._timeseries _vt_fc2;
                run;
                proc sort data=&out._timeseries; by Segment_No Metric Period_Index; run;

                /* early-warning urgency (flagged segments only, most urgent first) */
                proc sql;
                    create table &out._early_warning as
                    select Technique, Segment_Definition, Months_To_Breach, Confidence,
                           catx(': ', Technique, substr(strip(Segment_Definition), 1, 60)) as Label length=120
                    from &forecast where Early_Warning = 1
                    order by Months_To_Breach, Technique, Segment_Definition;
                quit;
                data &out._early_warning;
                    set &out._early_warning(obs=&n_early);
                    Rank = _n_;
                run;
            %end;
        %end;
    %end;
    /* sortable axis label: "01 JAN26", "02 FEB26", ... (alphabetical order = time order, so
       Visual Analytics needs no custom sort) */
    data &out._timeseries;
        set &out._timeseries;
        length Period_Label $70;
        Period_Label = catx(' ', put(Period_Index, z2.), strip(Period));
    run;
    proc datasets lib=work nolist nowarn; delete _vt_seg _vt_full _vt_fc _vt_fc2; quit;

    %put NOTE: seg_viz_prepare_trend - written &out._timeseries and (if a forecast exists) &out._early_warning;

%mend seg_viz_prepare_trend;
