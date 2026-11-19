/* ============================================================================
   seg_grid.sas
   Shared helpers for the AUTO-OPTIMISATION (grid search) of technique parameters,
   mirroring core/parameter_optimization.optimize_parameters:
       run the technique once per parameter combination, score each run by the SUM of
       Business_Impact_Score over the segments it returns, keep the FIRST combination with
       the strictly highest score.
   Every combination tried is recorded in <prefix>_param_search so the choice is
   explainable (what was tried, what it scored, which one won and why).

   Usage pattern inside a grid macro:
       %seg_grid_begin;
       ... for each combination k:  run technique with out_prefix=sgr&k
                                    %seg_grid_score(seg=sgr&k._segments, tech=..., combo=&k,
                                                    params=name=value name=value, into=sc);
                                    keep the best (strictly greater) ...
       %seg_grid_publish(best=&bestk, out_prefix=<final prefix>);
   Notes: the params= text must not contain commas or semicolons.
   ============================================================================ */
%macro seg_grid_begin;
    proc datasets lib=work nolist nowarn; delete _sg_psearch; quit;
%mend seg_grid_begin;

%macro seg_grid_score(seg=, tech=, combo=, params=, into=);
    %let &into = 0;
    %if %seg_nobs(&seg) > 0 %then %do;
        proc sql noprint;
            select coalesce(sum(Business_Impact_Score), 0) format=best32. into :&into trimmed from &seg;
        quit;
    %end;
    data _sg_ps1;
        length technique $30 combo 8 parameters $300 objective_score 8;
        technique = "&tech"; combo = &combo; parameters = "&params"; objective_score = &&&into;
    run;
    proc append base=_sg_psearch data=_sg_ps1 force; run;
    %put NOTE: seg_grid - &tech combination &combo (&params) objective score = &&&into;
%mend seg_grid_score;

%macro seg_grid_publish(best=, out_prefix=);
    %local tabs nt j t suffix;

    /* the winning run's tables become the technique's real output tables */
    proc sql noprint;
        select memname into :tabs separated by ' ' from dictionary.tables
        where libname = 'WORK' and substr(memname, 1, %eval(%length(SGR&best) + 1)) = upcase("SGR&best._");
    quit;
    %let nt = %sysfunc(countw(&tabs, %str( )));
    %do j = 1 %to &nt;
        %let t = %scan(&tabs, &j, %str( ));
        %let suffix = %substr(&t, %eval(%length(SGR&best) + 1));
        data &out_prefix.&suffix; set &t; run;
    %end;

    /* why this combination: every combination tried, its score, and the winner */
    proc sort data=_sg_psearch; by descending objective_score combo; run;
    data &out_prefix._param_search;
        length selection_rule $200;
        set _sg_psearch;
        rank_by_score = _n_;
        selected = (combo = &best);
        %if %seg_nobs(_sg_psearch) > 1 %then %do;
        selection_rule = 'Highest total Business_Impact_Score of the returned segments (first one wins a tie)';
        %end;
        %else %do;
        selection_rule = 'Only one combination was run (auto-optimisation off or a single value in the list)';
        %end;
    run;
    proc sort data=&out_prefix._param_search; by combo; run;

    proc datasets lib=work nolist nowarn; delete sgr: ; quit;
%mend seg_grid_publish;
