/* ============================================================================
   dq_foundational_profiling.sas
   (was %dq_tech1_profile in the old 10_dq_macros.sas)

   Per-column stats: completeness, cardinality, uniqueness, mean/std/min/max/
   skew/kurtosis/quantiles, IQR-based outlier count. One row per column in &out.

   Called by: dq_calc_wrapper.sas, drift_distribution_stats.sas
   ============================================================================ */
%macro dq_foundational_profiling(in_dataset=, out=);

    %local nobs allvars nvars i v vtype card nmiss
           mean std min max skew kurt q25 q50 q75 iqr lobnd hibnd nout;

    proc sql noprint;
        select count(*) into :nobs trimmed from &in_dataset;
    quit;

    proc contents data=&in_dataset out=_dq_cols_(keep=name type varnum) noprint;
    run;
    proc sort data=_dq_cols_; by varnum; run;

    proc sql noprint;
        select name into :allvars separated by '|' from _dq_cols_;
        select count(*) into :nvars trimmed from _dq_cols_;
    quit;

    data &out;
        length name $32 type 8 cardinality_count 8 missing_count 8
               completeness_pct 8 uniqueness_pct 8
               mean 8 std 8 min 8 max 8 skewness 8 kurtosis 8
               q25 8 q50 8 q75 8 n_outliers 8;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&allvars, &i, |);

        proc sql noprint;
            select type into :vtype trimmed from _dq_cols_ where upcase(name) = upcase("&v");
        quit;

        proc sql noprint;
            select count(distinct &v), sum(missing(&v))
                into :card trimmed, :nmiss trimmed
            from &in_dataset;
        quit;

        %let mean=.; %let std=.; %let min=.; %let max=.; %let skew=.; %let kurt=.;
        %let q25=.; %let q50=.; %let q75=.; %let nout=0;

        %if &vtype = 1 %then %do; /* numeric column */

            proc means data=&in_dataset noprint;
                var &v;
                output out=_dq_mstats_ mean=mean std=std min=min max=max
                                        skew=skew kurtosis=kurt
                                        p25=q25 p50=q50 p75=q75;
            run;

            data _null_;
                set _dq_mstats_;
                call symputx('mean', mean, 'L');
                call symputx('std',  std,  'L');
                call symputx('min',  min,  'L');
                call symputx('max',  max,  'L');
                call symputx('skew', skew, 'L');
                call symputx('kurt', kurt, 'L');
                call symputx('q25',  q25,  'L');
                call symputx('q50',  q50,  'L');
                call symputx('q75',  q75,  'L');
            run;

            %let iqr    = %sysevalf(&q75 - &q25);
            %let lobnd  = %sysevalf(&q25 - 1.5*&iqr);
            %let hibnd  = %sysevalf(&q75 + 1.5*&iqr);

            proc sql noprint;
                select count(*) into :nout trimmed
                from &in_dataset
                where &v is not missing and (&v < &lobnd or &v > &hibnd);
            quit;
        %end;

        proc sql;
            insert into &out
            values("&v", &vtype, &card, &nmiss,
                   %sysevalf(100*(1 - &nmiss/&nobs)),
                   %sysevalf(100*&card/%sysfunc(max(&nobs - &nmiss, 1))),
                   &mean, &std, &min, &max, &skew, &kurt,
                   &q25, &q50, &q75, &nout);
        quit;
    %end;

    proc datasets lib=work nolist;
        delete _dq_cols_ _dq_mstats_;
    quit;

%mend dq_foundational_profiling;
