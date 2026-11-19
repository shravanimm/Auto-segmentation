/* ============================================================================
   seg_viz_publish_cas.sas
   Publishes the chart tables to CAS so SAS Visual Analytics (or any CAS client) can read
   them. Each table is loaded into the caslib and PROMOTED (global scope), which is what makes it
   visible in Visual Analytics; optionally it is also saved as .sashdat so it survives a CAS restart.

   viz         : prefix of the chart tables (default viz)
   caslib      : target caslib (default casuser). For a shared report use a caslib the report users can read.
   tables      : which suffixes to publish
   persist     : Y = also save <table>.sashdat to the caslib's source path
   new_session : Y = start a CAS session first (cas _segviz;). Leave N when the program already has one
                 (SAS Studio normally starts one: check the CAS session indicator).
   Every CAS table gets the name <viz>_<suffix>, for example viz_bubble.
   ============================================================================ */
%macro seg_viz_publish_cas(viz=viz, caslib=casuser, tables=bubble heatmap waterfall timeseries early_warning,
                           persist=Y, new_session=N);

    %local i n t;

    %if %upcase(&new_session) = Y %then %do;
        cas _segviz;
        caslib _all_ assign;
    %end;

    %let n = %sysfunc(countw(&tables, %str( )));
    %do i = 1 %to &n;
        %let t = %scan(&tables, &i, %str( ));
        %if %sysfunc(exist(&viz._&t)) %then %do;
            proc casutil incaslib="&caslib" outcaslib="&caslib";
                droptable casdata="&viz._&t" quiet;
                load data=work.&viz._&t outcaslib="&caslib" casout="&viz._&t" promote;
                %if %upcase(&persist) = Y %then %do;
                    save casdata="&viz._&t" incaslib="&caslib" casout="&viz._&t..sashdat" outcaslib="&caslib" replace;
                %end;
            quit;
            %put NOTE: seg_viz_publish_cas - &viz._&t published to caslib &caslib;
        %end;
        %else %put NOTE: seg_viz_publish_cas - &viz._&t does not exist, skipped.;
    %end;

    /* list what is now in the caslib */
    proc casutil incaslib="&caslib";
        list tables;
    quit;

%mend seg_viz_publish_cas;
