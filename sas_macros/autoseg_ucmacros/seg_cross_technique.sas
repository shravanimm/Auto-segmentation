/* ============================================================================
   seg_cross_technique.sas
   Port of core/cross_technique_analysis.build_cross_technique_top10 over the
   techniques that produced segments:
     1  take each technique's worst 10 by Severity_Score (Feature Binning's
        Overall_Score plays that role; its Significant flag is the significance
        flag)
     2  collapse the same population found by several techniques into ONE row:
        fingerprint = (Dev_Count, Mon_Count, PSI, Delta_BR, Delta_Gini) rounded
        to 6 dp; keep the row with the highest Severity_Score, list every
        technique in Discovered_By, show the SHORTEST Segment_Definition
     3  Normalized_Root_Cause_Score = min-max of Root_Cause_Score over that pool
        (all equal => 0)
     4  top 10 by normalised score => Overall_Rank
   Severity_Score is comparable only WITHIN a technique; Root_Cause_Score (and
   its normalisation) is the cross-technique metric.
   prefixes : space-separated list of segment-table prefixes (<p>_segments)
   Outputs  : &out_prefix._combined (all returned segments, common columns)
              &out_prefix._cross_top10
   NOT included here: the per-technique head-to-head table (Overall_Score_100)
   and the executive-summary text (core/segment_insights); the LLM narrative
   stays outside SAS.
   ============================================================================ */
%macro seg_cross_technique(prefixes=, out_prefix=seg, per_technique_n=10, top_n=10);

    %local n i p dsid hasos rc rc_lo rc_hi;
    %let n = %sysfunc(countw(&prefixes, %str( )));

    data _xt_all;
        length Technique $40 Segment_Definition $1000 Root_Cause_Feature $64
               Dev_Count Mon_Count Dev_Pct Mon_Pct PSI Delta_BR Delta_Gini Delta_KS
               Severity_Score Root_Cause_Score Statistically_Significant Rank 8;
        stop;
    run;

    %do i = 1 %to &n;
        %let p = %scan(&prefixes, &i, %str( ));
        %if %seg_nobs(&p._segments) > 0 %then %do;
            %let dsid  = %sysfunc(open(&p._segments));
            %let hasos = %sysfunc(varnum(&dsid, Overall_Score));
            %let rc    = %sysfunc(close(&dsid));
            data _xt_one;
                set &p._segments;
                %if &hasos > 0 %then %do;
                    Severity_Score = Overall_Score;
                    Statistically_Significant = Significant;
                %end;
                keep Technique Segment_Definition Root_Cause_Feature Dev_Count Mon_Count Dev_Pct Mon_Pct
                     PSI Delta_BR Delta_Gini Delta_KS Severity_Score Root_Cause_Score
                     Statistically_Significant Rank;
            run;
            proc append base=_xt_all data=_xt_one force; run;
        %end;
    %end;

    data &out_prefix._combined; set _xt_all; run;

    /* 1. per-technique worst N by Severity_Score */
    proc sort data=_xt_all out=_xt_s; by Technique descending Severity_Score Rank; run;
    data _xt_w;
        set _xt_s; by Technique;
        if first.Technique then _k = 0;
        _k + 1;
        if _k <= &per_technique_n;
        drop _k;
    run;

    /* 2. same population found by several techniques */
    data _xt_f;
        set _xt_w;
        length fp $200;
        if missing(Dev_Count) or missing(Mon_Count) then fp = cats('row', put(_n_, best12.));
        else fp = catx('|', Dev_Count, Mon_Count, put(round(PSI, 1e-6), best20.),
                       put(round(Delta_BR, 1e-6), best20.), put(round(Delta_Gini, 1e-6), best20.));
    run;

    proc sort data=_xt_f out=_xt_fs; by fp Technique; run;
    data _xt_agg(keep=fp Discovered_By short_def);
        length Discovered_By $200 short_def $1000 prev $40;
        do until(last.fp);
            set _xt_fs; by fp;
            if first.fp then do;
                Discovered_By = Technique; short_def = Segment_Definition; prev = Technique;
            end;
            else do;
                if Technique ne prev then Discovered_By = catx(', ', Discovered_By, Technique);
                prev = Technique;
                if length(strip(Segment_Definition)) < length(strip(short_def)) then short_def = Segment_Definition;
            end;
        end;
        output;
    run;

    proc sort data=_xt_f out=_xt_fb; by fp descending Severity_Score; run;
    data _xt_best; set _xt_fb; by fp; if first.fp; run;
    data _xt_pool;
        merge _xt_best(in=_a) _xt_agg;
        by fp;
        if _a;
        Segment_Definition = short_def;
        drop short_def fp;
    run;

    /* 3 + 4. normalise Root_Cause_Score over the merged pool, rank */
    proc sql noprint;
        select min(coalesce(Root_Cause_Score, 0)) format=best32., max(coalesce(Root_Cause_Score, 0)) format=best32.
          into :rc_lo trimmed, :rc_hi trimmed from _xt_pool;
    quit;
    data _xt_n;
        set _xt_pool;
        _rc = coalesce(Root_Cause_Score, 0);
        if &rc_hi - &rc_lo > 1e-9 then Normalized_Root_Cause_Score = (_rc - &rc_lo) / (&rc_hi - &rc_lo);
        else Normalized_Root_Cause_Score = 0;
        drop _rc;
    run;
    proc sort data=_xt_n; by descending Normalized_Root_Cause_Score descending Severity_Score; run;
    data &out_prefix._cross_top10;
        set _xt_n(obs=&top_n);
        Overall_Rank = _n_;
    run;

%mend seg_cross_technique;
