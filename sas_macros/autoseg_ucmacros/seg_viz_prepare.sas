/* ============================================================================
   seg_viz_prepare.sas
   Chart-ready tables for the SEGMENT charts of the Python project (utils/charts.py):
     bubble chart (population vs Gini drop, size = exposure), segment x metric heatmap,
     SIS waterfall. The tables are "tidy" (one row per plotted mark) so both PROC SGPLOT
     and SAS Visual Analytics can use them without any calculation.

   seg      : any segment table of this module: <p>_<tech>_segments, <p>_cross_top10 or
              <p>_summary (trend). Needs Segment_Definition, Mon_Pct, Delta_Gini.
              Optional: Technique, Mon_Exposure_Pct, Business_Impact_Score, PSI, Delta_KS,
              Delta_BR, Root_Cause_Score (a missing optional column is treated as 0 / default).
   out      : prefix of the tables written (default viz)
   label_len: segment label length (Python: 40 characters)
   w_*      : waterfall weights (Python defaults: 0.25 / 0.25 / 0.20 / 0.15 / 0.15)

   OUTPUT (WORK data sets)
     <out>_base       one row per segment: seg_id, Segment_Label ("1. text"), Technique, source metrics
     <out>_bubble     Technique, Segment_Label, Mon_Pct, Gini_Drop = max(0, -Delta_Gini),
                      Exposure (Mon_Exposure_Pct, 0.02 if missing, 0.05 if the column is absent),
                      Bubble_Size = 200 + 3000 * Exposure
     <out>_heatmap    long: seg_id, Segment_Label, Metric, Metric_Order, Value, Value_Normalised
                      ((x - min) / (max - min + 1e-9) per metric), Value_Text
     <out>_waterfall  long: seg_id, Segment_Label, Component, Order, Contribution, Base, End, Mid, Kind
                      (components PSI, Business Impact, Gini Drop, KS Drop, Bad-Rate Shift, then the
                      SIS_Raw total); the first segment is the one Python draws
   ============================================================================ */
%macro seg_viz_prepare(seg=, out=viz, label_len=40, w_psi=0.25, w_bi=0.25, w_gini=0.20, w_ks=0.15, w_br=0.15);

    %local dsid rc hasT hasE hasB mlist nm i m lo hi;

    %if not %sysfunc(exist(&seg)) %then %do;
        %put ERROR: seg_viz_prepare - table &seg does not exist.;
        %return;
    %end;
    %if %seg_nobs(&seg) = 0 %then %do;
        %put NOTE: seg_viz_prepare - &seg has no rows, nothing to prepare.;
        %return;
    %end;

    /* which optional columns exist */
    %let dsid = %sysfunc(open(&seg));
    %let hasT = %sysfunc(varnum(&dsid, Technique));
    %let hasE = %sysfunc(varnum(&dsid, Mon_Exposure_Pct));
    %let hasB = %sysfunc(varnum(&dsid, Business_Impact_Score));
    %let mlist = ;
    %do i = 1 %to 5;
        %let m = %scan(PSI Delta_Gini Delta_KS Delta_BR Root_Cause_Score, &i, %str( ));
        %if %sysfunc(varnum(&dsid, &m)) > 0 %then %let mlist = &mlist &m;
    %end;
    %let rc = %sysfunc(close(&dsid));
    %let nm = %sysfunc(countw(&mlist, %str( )));

    /* ---- base table: one row per segment, labelled and numbered in table order ---- */
    data &out._base;
        set &seg;
        length Segment_Label $80;
        seg_id = _n_;
        Segment_Label = catx(' ', cats(put(seg_id, z2.), '.'), substr(strip(Segment_Definition), 1, &label_len));
        %if not &hasT %then %do; length Technique $40; Technique = 'All'; %end;
        _gd = ifn(missing(Delta_Gini), 0, max(0, -Delta_Gini));
        %if &hasE %then %do; _exp = coalesce(Mon_Exposure_Pct, 0.02); %end;
        %else %do;           _exp = 0.05; %end;
        %if &hasB %then %do; _bi = coalesce(Business_Impact_Score, 0); %end;
        %else %do;           _bi = 0; %end;
    run;

    /* ---- bubble chart ---- */
    data &out._bubble;
        set &out._base;
        Gini_Drop   = _gd;
        Exposure    = max(_exp, 0);
        Bubble_Size = 200 + 3000 * max(_exp, 0);
        keep seg_id Technique Segment_Label Mon_Pct Gini_Drop Exposure Bubble_Size;
    run;

    /* ---- heatmap (long format, normalised per metric) ---- */
    %if &nm > 0 %then %do;
        %do i = 1 %to &nm;
            %let m = %scan(&mlist, &i, %str( ));
            proc sql noprint;
                select min(coalesce(&m, 0)) format=best32., max(coalesce(&m, 0)) format=best32.
                  into :lo trimmed, :hi trimmed from &out._base;
            quit;
            data _vz_h&i;
                set &out._base(keep=seg_id Segment_Label &m);
                length Metric $32 Value_Text $16 Metric_Label $40;
                Metric = "&m";
                Metric_Order = &i;
                Metric_Label = catx(' ', put(Metric_Order, 1.), Metric);   /* sortable label for VA */
                Value = coalesce(&m, 0);
                Value_Normalised = (Value - &lo) / (&hi - &lo + 1e-9);
                Value_Text = strip(put(Value, 8.3));
                keep seg_id Segment_Label Metric Metric_Label Metric_Order Value Value_Normalised Value_Text;
            run;
        %end;
        data &out._heatmap;
            set _vz_h1-_vz_h&nm;
        run;
        proc sort data=&out._heatmap; by seg_id Metric_Order; run;
        proc datasets lib=work nolist nowarn; delete _vz_h1-_vz_h&nm; quit;
    %end;

    /* ---- SIS waterfall for every segment (VA / SGPLOT pick the segment with a filter) ---- */
    data &out._waterfall;
        set &out._base;
        length Component $24 Kind $10;
        %if %sysfunc(indexw(&mlist, PSI)) %then %do; _psi = max(0, coalesce(PSI, 0)); %end; %else %do; _psi = 0; %end;
        %if %sysfunc(indexw(&mlist, Delta_KS)) %then %do; _ks = max(0, -coalesce(Delta_KS, 0)); %end; %else %do; _ks = 0; %end;
        %if %sysfunc(indexw(&mlist, Delta_BR)) %then %do; _br = max(0, coalesce(Delta_BR, 0)); %end; %else %do; _br = 0; %end;
        _cum = 0;
        Kind = 'Component';
        Component = 'PSI';            Order = 1; Contribution = &w_psi * _psi;   Base = _cum; _cum = _cum + Contribution; End = _cum; Mid = (Base + End) / 2; output;
        Component = 'Business Impact'; Order = 2; Contribution = &w_bi * _bi;    Base = _cum; _cum = _cum + Contribution; End = _cum; Mid = (Base + End) / 2; output;
        Component = 'Gini Drop';      Order = 3; Contribution = &w_gini * _gd;   Base = _cum; _cum = _cum + Contribution; End = _cum; Mid = (Base + End) / 2; output;
        Component = 'KS Drop';        Order = 4; Contribution = &w_ks * _ks;     Base = _cum; _cum = _cum + Contribution; End = _cum; Mid = (Base + End) / 2; output;
        Component = 'Bad-Rate Shift'; Order = 5; Contribution = &w_br * _br;     Base = _cum; _cum = _cum + Contribution; End = _cum; Mid = (Base + End) / 2; output;
        Kind = 'Total';
        Component = 'SIS_Raw';        Order = 6; Contribution = _cum; Base = 0; End = _cum; Mid = _cum / 2; output;
        keep seg_id Segment_Label Component Order Contribution Base End Mid Kind;
    run;
    data &out._waterfall;
        set &out._waterfall;
        length Contribution_Text $16;
        Contribution_Text = strip(put(Contribution, 8.3));
        /* sortable axis label for Visual Analytics ("1 PSI", "2 Business Impact", ...) */
        length Component_Label $32;
        Component_Label = catx(' ', put(Order, 1.), Component);
    run;

    %put NOTE: seg_viz_prepare - written &out._bubble &out._heatmap &out._waterfall (%seg_nobs(&out._base) segments);

%mend seg_viz_prepare;
