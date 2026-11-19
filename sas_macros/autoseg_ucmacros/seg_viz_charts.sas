/* ============================================================================
   seg_viz_charts.sas
   Draws the Python project's figures with PROC SGPLOT from the tables of
   seg_viz_prepare / seg_viz_prepare_trend. The charts appear in the SAS Studio Results
   tab; to save them as image files set  ods listing gpath="<server folder>";  before
   the call (each chart is named seg_<chart>).

   viz       : prefix of the chart tables (default viz)
   charts    : BUBBLE HEATMAP WATERFALL TIMESERIES EARLY   (default: all that exist)
   wf_seg    : waterfall - seg_id of the segment drawn (1 = top segment, as in Python)
   ts_seg    : time series - Segment_No of the segment drawn (1 = first)

   Python figure                      SAS chart (statement)
   segment_bubble_chart               BUBBLE   (bubble, colour = technique)
   segment_metric_heatmap             HEATMAP  (heatmapparm + text, green to red)
   sis_waterfall_chart                WATERFALL (highlow bars, red components, green total)
   segment_all_metrics_chart / _time_series_chart   TIMESERIES (series, forecast dashed red)
   early_warning_urgency_chart        EARLY    (hbarparm, colour = confidence)
   ============================================================================ */
%macro seg_viz_charts(viz=viz, charts=BUBBLE HEATMAP WATERFALL TIMESERIES EARLY, wf_seg=1, ts_seg=1);

    %local c i lbl key;
    %let charts = %upcase(&charts);

    ods graphics / reset width=7.5in height=5in;

    /* ------------------------------------------------------------ bubble */
    %if %index(&charts, BUBBLE) and %sysfunc(exist(&viz._bubble)) %then %do;
        ods graphics / imagename="seg_bubble";
        title "Segment Impact Bubble Chart (bubble size = exposure pct)";
        proc sgplot data=&viz._bubble;
            bubble x=Mon_Pct y=Gini_Drop size=Exposure / group=Technique transparency=0.4
                   bradiusmin=8px bradiusmax=38px;
            xaxis label="Monitoring Population Pct";
            yaxis label="Gini Drop (positive = worse)";
            keylegend / title="Technique";
        run;
        title;
    %end;

    /* ------------------------------------------------------------ heatmap */
    %if %index(&charts, HEATMAP) and %sysfunc(exist(&viz._heatmap)) %then %do;
        ods graphics / imagename="seg_heatmap" height=6in;
        title "Segment x Metric Heatmap";
        proc sgplot data=&viz._heatmap;
            heatmapparm x=Metric y=Segment_Label colorresponse=Value_Normalised /
                        colormodel=(CX2CA02C CXFFEB84 CXD62728) outline;
            text x=Metric y=Segment_Label text=Value_Text / textattrs=(size=7);
            xaxis display=(nolabel) discreteorder=data;
            yaxis display=(nolabel) discreteorder=data reverse;
            gradlegend / title="Normalized severity";
        run;
        title;
    %end;

    /* ------------------------------------------------------------ waterfall */
    %if %index(&charts, WATERFALL) and %sysfunc(exist(&viz._waterfall)) %then %do;
        data _vz_wf;
            set &viz._waterfall;
            where seg_id = &wf_seg;
        run;
        %let lbl = ;
        proc sql noprint; select distinct Segment_Label into :lbl trimmed from _vz_wf; quit;
        ods graphics / imagename="seg_waterfall" height=4.5in;
        title "SIS Waterfall - &lbl";
        proc sgplot data=_vz_wf noautolegend;
            styleattrs datacolors=(CXD62728 CX2CA02C);
            highlow x=Component low=Base high=End / type=bar group=Kind barwidth=0.7;
            text x=Component y=Mid text=Contribution_Text / textattrs=(size=8);
            xaxis display=(nolabel) discreteorder=data;
            yaxis label="Contribution to SIS_Raw";
        run;
        title;
    %end;

    /* ------------------------------------------------------------ time series */
    %if %index(&charts, TIMESERIES) and %sysfunc(exist(&viz._timeseries)) %then %do;
        data _vz_ts;
            set &viz._timeseries;
            where Segment_No = &ts_seg;
        run;
        %let key = ;
        proc sql noprint; select distinct Segment_Key into :key trimmed from _vz_ts; quit;
        data _vz_attr;
            length id $8 value $40 linecolor markercolor $12 linepattern $12 markersymbol $16;
            id = 'm'; linepattern = 'solid'; markersymbol = 'circlefilled';
            value = 'Population Pct';                 linecolor = 'CX1F77B4'; markercolor = linecolor; output;
            value = 'AUC';                          linecolor = 'CX2CA02C'; markercolor = linecolor; output;
            value = 'Bad Rate';                     linecolor = 'CXD62728'; markercolor = linecolor; output;
            value = 'Root Cause Score';             linecolor = 'CX9467BD'; markercolor = linecolor; output;
            value = 'Root Cause Score (forecast)';  linecolor = 'CXD62728'; markercolor = linecolor; linepattern = 'shortdash'; output;
        run;
        ods graphics / imagename="seg_timeseries" width=9in height=4.2in;
        title "All Key Metrics Over Time - &key";
        proc sgplot data=_vz_ts dattrmap=_vz_attr;
            series x=Period y=Value / group=Metric attrid=m markers break;
            xaxis display=(nolabel) discreteorder=data;
            yaxis label="Value (0-1 scale)" min=-0.02 max=1.02;
            keylegend / position=right;
        run;
        title;
    %end;

    /* ------------------------------------------------------------ early warning */
    %if %index(&charts, EARLY) and %sysfunc(exist(&viz._early_warning)) %then %do;
        %if %seg_nobs(&viz._early_warning) > 0 %then %do;
            data _vz_eattr;
                length id $8 value $40 fillcolor linecolor $12;
                id = 'c'; linecolor = 'CX7C2D12';
                value = 'Medium (3+ points)'; fillcolor = 'CXF97316'; output;
                value = 'Low (2 points)';     fillcolor = 'CXFDBA74'; output;
            run;
            ods graphics / imagename="seg_early_warning" width=8in height=4in;
            title "Early Warning - Most Urgent Segments";
            proc sgplot data=&viz._early_warning dattrmap=_vz_eattr;
                hbarparm category=Label response=Months_To_Breach / group=Confidence attrid=c datalabel;
                yaxis display=(nolabel) discreteorder=data reverse;
                xaxis label="Months Until Projected to Cross Alert Threshold";
                keylegend / title="Confidence";
            run;
            title;
        %end;
        %else %put NOTE: seg_viz_charts - no segment is flagged as an early warning.;
    %end;

    ods graphics / reset;
    proc datasets lib=work nolist nowarn; delete _vz_wf _vz_ts _vz_attr _vz_eattr; quit;

%mend seg_viz_charts;
