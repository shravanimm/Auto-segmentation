/* ============================================================================
   seg_viz_from_cas.sas
   READ the chart tables back from CAS and draw the charts - this is how any SAS program (or a scheduled
   job) can use the published tables, independent of the run that created them.

   viz     : prefix of the CAS tables (viz -> viz_bubble, viz_heatmap, ...)
   caslib  : caslib that holds them (they must be loaded or promoted there, see seg_viz_publish_cas)
   charts  : passed to seg_viz_charts
   Steps   : 1. libname ... cas caslib=...  (a SAS libref for the caslib)
             2. copy each table to WORK (the SGPLOT procedure then works exactly as on local data)
             3. %seg_viz_charts
   ============================================================================ */
%macro seg_viz_from_cas(viz=viz, caslib=casuser, charts=BUBBLE HEATMAP WATERFALL TIMESERIES EARLY, wf_seg=1, ts_seg=1);

    %local i t;
    libname _vzcas cas caslib="&caslib";

    %do i = 1 %to 5;
        %let t = %scan(bubble heatmap waterfall timeseries early_warning, &i, %str( ));
        %if %sysfunc(exist(_vzcas.&viz._&t)) %then %do;
            data work.&viz._&t;
                set _vzcas.&viz._&t;
            run;
        %end;
        %else %put NOTE: seg_viz_from_cas - table &viz._&t not found in caslib &caslib;
    %end;

    %seg_viz_charts(viz=&viz, charts=&charts, wf_seg=&wf_seg, ts_seg=&ts_seg);

    libname _vzcas clear;

%mend seg_viz_from_cas;
