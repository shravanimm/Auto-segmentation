/* ============================================================================
   10_dq_macros.sas
   Data Quality macros - modeled on the EDA project rule logic (analyze_rules.py /
   insights.py): missingness blockers, zero-variance blockers, identifier /
   leakage governance flags, and a weighted per-column health score.

   Entry point: %dq_calc_wrapper
   Called by  : %main_wrapper (see 00_main_wrapper.sas)
   ============================================================================ */

/* ----------------------------------------------------------------------------
   %dq_calc_wrapper — orchestrates the 4 DQ techniques for one dataset.
   ---------------------------------------------------------------------------- */
%macro dq_calc_wrapper(in_dataset=, out_prefix=, target_col=, id_cols=, private_cols=,
                        missing_thresh=50, id_uniqueness_thresh=99.9, leakage_card_min=50);

    %dq_tech1_profile(in_dataset=&in_dataset, out=&out_prefix._profile);

    %dq_tech2_blockers(profile=&out_prefix._profile, out=&out_prefix._blockers,
                        missing_thresh=&missing_thresh);

    %dq_tech3_governance(profile=&out_prefix._profile, out=&out_prefix._governance,
                          id_cols=&id_cols, private_cols=&private_cols, target_col=&target_col,
                          id_uniqueness_thresh=&id_uniqueness_thresh,
                          leakage_card_min=&leakage_card_min);

    %dq_tech4_healthscore(profile=&out_prefix._profile, blockers=&out_prefix._blockers,
                           governance=&out_prefix._governance, out=&out_prefix._health);

    %put NOTE: DQ complete for &in_dataset -> &out_prefix._profile / _blockers / _governance / _health;

%mend dq_calc_wrapper;


/* ----------------------------------------------------------------------------
   %dq_tech1_profile — per-column stats: completeness, cardinality, uniqueness,
   mean/std/min/max/skew/kurtosis/quantiles, IQR-based outlier count.
   One row per column in &out.
   ---------------------------------------------------------------------------- */
%macro dq_tech1_profile(in_dataset=, out=);

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

%mend dq_tech1_profile;


/* ----------------------------------------------------------------------------
   %dq_tech2_blockers — EDA-style blocker rules:
     high_missing   : completeness_pct < &missing_thresh
     zero_variance  : cardinality_count <= 1
   ---------------------------------------------------------------------------- */
%macro dq_tech2_blockers(profile=, out=, missing_thresh=50);

    data &out;
        set &profile;
        length rule $20 detail $200;
        if completeness_pct < &missing_thresh then do;
            rule = "high_missing";
            detail = catx(' ', put(completeness_pct,8.1), "% complete -", missing_count, "rows missing");
            output;
        end;
        if cardinality_count <= 1 then do;
            rule = "zero_variance";
            detail = catx(' ', "Only", cardinality_count, "unique value(s) - zero predictive signal");
            output;
        end;
        keep name rule detail;
    run;

%mend dq_tech2_blockers;


/* ----------------------------------------------------------------------------
   %dq_tech3_governance — EDA-style governance rules:
     IDENTIFIER : uniqueness_pct >= &id_uniqueness_thresh, or name listed in id_cols
     LEAKAGE    : numeric, min>=0, max<=1, cardinality>=&leakage_card_min, not target
     PRIVACY    : name listed in private_cols (cannot be inferred from data alone -
                  pass the known-sensitive column list explicitly, e.g. private_cols=age region)
   ---------------------------------------------------------------------------- */
%macro dq_tech3_governance(profile=, out=, id_cols=, private_cols=, target_col=,
                            id_uniqueness_thresh=99.9, leakage_card_min=50);

    data &out;
        set &profile;
        length risk_type $12 detail $200;

        if uniqueness_pct >= &id_uniqueness_thresh
           %if %length(&id_cols) %then or indexw(upcase("&id_cols"), upcase(trim(name))) > 0;
           then do;
            risk_type = "IDENTIFIER";
            detail = catx(' ', "Uniqueness", put(uniqueness_pct,8.1), "% - surrogate key, exclude from features");
            output;
        end;

        if type = 1 and min >= 0 and max <= 1 and cardinality_count >= &leakage_card_min
           %if %length(&target_col) %then and upcase(name) ne upcase("&target_col");
           then do;
            risk_type = "LEAKAGE";
            detail = "Bounded [0,1], high cardinality - resembles a model probability output";
            output;
        end;

        %if %length(&private_cols) %then %do;
        if indexw(upcase("&private_cols"), upcase(trim(name))) > 0
            then do;
            risk_type = "PRIVACY";
            detail = "Listed as a privacy-sensitive attribute";
            output;
        end;
        %end;

        keep name risk_type detail;
    run;

%mend dq_tech3_governance;


/* ----------------------------------------------------------------------------
   %dq_tech4_healthscore — weighted composite per column (0-100) +
   dataset-level readiness score. Weights are adjustable arguments.
   ---------------------------------------------------------------------------- */
%macro dq_tech4_healthscore(profile=, blockers=, governance=, out=,
                             w_completeness=0.35, w_variance=0.25,
                             w_governance=0.25, w_distribution=0.15);

    proc sql;
        create table _dq_blk_flag_ as
        select distinct name from &blockers;
        create table _dq_gov_flag_ as
        select distinct name from &governance;
    quit;

    proc sql;
        create table &out as
        select p.name,
               (p.completeness_pct / 100)                       as completeness_score,
               (p.cardinality_count > 1)                         as variance_score,
               (1 - 0.6*(g.name is not null))                    as governance_score,
               ((p.type ne 1) or (abs(p.skewness) < 1))          as distribution_score,
               case when b.name is not null then 0
                    else round(100 * (
                        &w_completeness * (p.completeness_pct / 100)
                      + &w_variance     * (p.cardinality_count > 1)
                      + &w_governance   * (1 - 0.6*(g.name is not null))
                      + &w_distribution * ((p.type ne 1) or (abs(p.skewness) < 1))
                    ), 0.1)
               end                                                as health_score,
               case when b.name is not null then "drop"
                    when g.name is not null then "caution"
                    else "ready" end                              as status length=8
        from &profile p
        left join _dq_blk_flag_ b on p.name = b.name
        left join _dq_gov_flag_ g on p.name = g.name;
    quit;

    proc means data=&out noprint;
        var health_score;
        output out=_dq_readiness_(drop=_type_ _freq_) mean=readiness_score;
    run;

    %global &out._readiness;
    data _null_;
        set _dq_readiness_;
        call symputx("&out._readiness", round(readiness_score,0.1), 'G');
    run;
    %put NOTE: Dataset readiness score for &profile = &&&out._readiness;

    proc datasets lib=work nolist;
        delete _dq_blk_flag_ _dq_gov_flag_ _dq_readiness_;
    quit;

%mend dq_tech4_healthscore;
