/* ============================================================================
   dq_healthscore.sas
   (was %dq_tech4_healthscore in the old 10_dq_macros.sas)

   Weighted composite per column (0-100) + dataset-level readiness score.
   Weights are adjustable arguments.

   Called by: dq_calc_wrapper.sas
   ============================================================================ */
%macro dq_healthscore(profile=, blockers=, governance=, out=,
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

%mend dq_healthscore;
