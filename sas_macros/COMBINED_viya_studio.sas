/* ============================================================================
   COMBINED_viya_studio.sas
   Paste this ENTIRE file into the Code editor in SAS Data and AI Studio and
   click Run. It connects to the CAS caslib where v2_development_data and
   v2_monitoring_2026_01 already live (per SAS Data Hub), then defines and
   runs the Data Quality + Drift macros against them.
   ============================================================================ */

/* ---- Point at the existing CAS tables (no import needed - already loaded) ---- */
cas;
libname public cas caslib="Public";


/* ============================================================================
   10_dq_macros.sas - Data Quality (modeled on the EDA project rule logic)
   ============================================================================ */
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

        %if &vtype = 1 %then %do;
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


/* ============================================================================
   20_drift_macros.sas — Data Drift (our own logic)
   ============================================================================ */
%macro drift_calc_wrapper(dev_dataset=, mon_dataset=, out_prefix=drift,
                           target_col=, score_col=, feature_cols=, categorical_cols=,
                           psi_stable=0.10, psi_shift=0.25, ks_stable=0.10, ks_shift=0.20);
    %drift_tech1_schema(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._schema);
    %drift_tech2_completeness(dev=&dev_dataset, mon=&mon_dataset,
                               out=&out_prefix._completeness);
    %if %length(&feature_cols) %then %do;
        %drift_tech3_csi(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._csi,
                          feature_cols=&feature_cols,
                          psi_stable=&psi_stable, psi_shift=&psi_shift);

        %drift_tech6_distribution_stats(dev=&dev_dataset, mon=&mon_dataset,
                                         out=&out_prefix._distribution);

        %drift_tech8_ks(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._ks,
                         feature_cols=&feature_cols, ks_stable=&ks_stable, ks_shift=&ks_shift);
    %end;
    %if %length(&score_col) %then %do;
        %drift_tech4_score_psi(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._score_psi,
                                score_col=&score_col,
                                psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;
    %if %length(&target_col) %then %do;
        %drift_tech5_target(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._target,
                             target_col=&target_col);
    %end;
    %if %length(&categorical_cols) %then %do;
        %drift_tech7_entropy(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._entropy,
                              categorical_cols=&categorical_cols);

        %drift_tech9_categorical_psi(dev=&dev_dataset, mon=&mon_dataset,
                                      out=&out_prefix._categorical_psi,
                                      categorical_cols=&categorical_cols,
                                      psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;
    %put NOTE: Drift analysis complete: &dev_dataset vs &mon_dataset -> &out_prefix._*;
%mend drift_calc_wrapper;

%macro drift_tech1_schema(dev=, mon=, out=);
    proc contents data=&dev out=_drift_devcols_(keep=name type length) noprint; run;
    proc contents data=&mon out=_drift_moncols_(keep=name type length) noprint; run;

    proc sql;
        create table &out as
        select coalesce(d.name, m.name) as name length=32,
               case
                   when d.name is null then "added"
                   when m.name is null then "dropped"
                   when d.type ne m.type or d.length ne m.length then "type_changed"
                   else "unchanged"
               end as change_type length=12,
               d.type as dev_type, m.type as mon_type,
               d.length as dev_length, m.length as mon_length
        from _drift_devcols_ d
        full join _drift_moncols_ m on upcase(d.name) = upcase(m.name);
    quit;

    proc datasets lib=work nolist;
        delete _drift_devcols_ _drift_moncols_;
    quit;
%mend drift_tech1_schema;

%macro drift_tech2_completeness(dev=, mon=, out=, delta_alert=5);
    %local devn monn;
    proc sql noprint;
        select count(*) into :devn trimmed from &dev;
        select count(*) into :monn trimmed from &mon;
    quit;

    proc contents data=&dev out=_drift_c1_(keep=name) noprint; run;
    proc contents data=&mon out=_drift_c2_(keep=name) noprint; run;
    proc sql;
        create table _drift_common_ as
        select upcase(a.name) as name from _drift_c1_ a
        inner join _drift_c2_ b on upcase(a.name) = upcase(b.name);
    quit;

    %local nvars i v commonvars dev_miss mon_miss dev_pct mon_pct delta;
    proc sql noprint;
        select count(*), name into :nvars trimmed, :commonvars separated by '|'
        from _drift_common_;
    quit;

    %do i = 1 %to &nvars;
        %let v = %scan(&commonvars, &i, |);

        proc sql noprint;
            select sum(missing(&v)) into :dev_miss trimmed from &dev;
            select sum(missing(&v)) into :mon_miss trimmed from &mon;
        quit;

        %let dev_pct = %sysevalf(100*(1 - &dev_miss/&devn));
        %let mon_pct = %sysevalf(100*(1 - &mon_miss/&monn));
        %let delta   = %sysevalf(&mon_pct - &dev_pct);

        data _drift_cd_&i;
            length name $32 pattern $20;
            name                  = "&v";
            dev_completeness_pct  = &dev_pct;
            mon_completeness_pct  = &mon_pct;
            delta_pp              = &delta;
            %if %sysevalf(&delta <= -&delta_alert) %then %do;
                pattern = "growing_missing";
            %end;
            %else %if %sysevalf(&delta >= &delta_alert) %then %do;
                pattern = "recovering";
            %end;
            %else %do;
                pattern = "stable_missing";
            %end;
        run;
    %end;

    data &out;
        set _drift_cd_1 - _drift_cd_&nvars;
    run;

    proc datasets lib=work nolist;
        delete _drift_c1_ _drift_c2_ _drift_common_ _drift_cd_1-_drift_cd_&nvars;
    quit;
%mend drift_tech2_completeness;

%macro drift_tech3_csi(dev=, mon=, out=, feature_cols=, psi_stable=0.10, psi_shift=0.25);
    %local nvars i v;
    %let nvars = %sysfunc(countw(&feature_cols));

    data &out;
        length feature $32 csi 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&feature_cols, &i);
        %_psi_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                           name_col=feature, psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;
%mend drift_tech3_csi;

%macro drift_tech4_score_psi(dev=, mon=, out=, score_col=, psi_stable=0.10, psi_shift=0.25);
    data _score_psi_raw_;
        length feature $32 csi 8 label $10;
        stop;
    run;

    %_psi_one_feature(dev=&dev, mon=&mon, var=&score_col, out=_score_psi_raw_,
                       name_col=feature, psi_stable=&psi_stable, psi_shift=&psi_shift);

    proc sql;
        create table &out as
        select feature as score_column, csi as psi, label
        from _score_psi_raw_;
    quit;

    proc datasets lib=work nolist;
        delete _score_psi_raw_;
    quit;
%mend drift_tech4_score_psi;

%macro _psi_one_feature(dev=, mon=, var=, out=, name_col=feature,
                         psi_stable=0.10, psi_shift=0.25);
    proc rank data=&dev groups=10 out=_psi_devrank_(keep=&var _bucket_);
        var &var;
        ranks _bucket_;
    run;

    proc means data=_psi_devrank_ noprint;
        class _bucket_;
        var &var;
        output out=_psi_bounds_(where=(_type_=1)) max=upper;
    run;

    proc sql noprint;
        select upper into :cut1-:cut9 from _psi_bounds_ where _bucket_ in (0,1,2,3,4,5,6,7,8) order by _bucket_;
    quit;

    %macro _bucket_expr(v);
        (case
            when &v <= &cut1 then 0
            when &v <= &cut2 then 1
            when &v <= &cut3 then 2
            when &v <= &cut4 then 3
            when &v <= &cut5 then 4
            when &v <= &cut6 then 5
            when &v <= &cut7 then 6
            when &v <= &cut8 then 7
            when &v <= &cut9 then 8
            else 9
         end)
    %mend _bucket_expr;

    proc sql;
        create table _psi_dev_pct_ as
        select %_bucket_expr(&var) as bucket, count(*)/(select count(*) from &dev where &var is not missing) as pct
        from &dev where &var is not missing
        group by bucket;

        create table _psi_mon_pct_ as
        select %_bucket_expr(&var) as bucket, count(*)/(select count(*) from &mon where &var is not missing) as pct
        from &mon where &var is not missing
        group by bucket;
    quit;

    proc sql;
        create table _psi_joined_ as
        select coalesce(d.bucket, m.bucket) as bucket,
               coalesce(d.pct, 0.000001) as dev_pct,
               coalesce(m.pct, 0.000001) as mon_pct
        from _psi_dev_pct_ d full join _psi_mon_pct_ m on d.bucket = m.bucket;
    quit;

    proc sql noprint;
        select sum((mon_pct - dev_pct) * log(mon_pct / dev_pct))
            into :psi_val trimmed
        from _psi_joined_;
    quit;

    %local psi_label;
    %if %sysevalf(&psi_val < &psi_stable) %then %let psi_label = stable;
    %else %if %sysevalf(&psi_val < &psi_shift) %then %let psi_label = monitor;
    %else %let psi_label = shift;

    proc sql;
        insert into &out
        values("&var", %sysfunc(round(&psi_val, 0.0001)), "&psi_label");
    quit;

    proc datasets lib=work nolist;
        delete _psi_devrank_ _psi_bounds_ _psi_dev_pct_ _psi_mon_pct_ _psi_joined_;
    quit;
%mend _psi_one_feature;

%macro drift_tech5_target(dev=, mon=, out=, target_col=, drift_notable=3, drift_critical=8);
    %local dev_rate mon_rate delta_pp label;

    proc sql noprint;
        select mean(&target_col)*100 into :dev_rate trimmed from &dev;
        select mean(&target_col)*100 into :mon_rate trimmed from &mon;
    quit;

    %let delta_pp = %sysevalf(&mon_rate - &dev_rate);

    %if %sysevalf(%sysfunc(abs(&delta_pp)) < &drift_notable) %then %let label = stable;
    %else %if %sysevalf(%sysfunc(abs(&delta_pp)) < &drift_critical) %then %let label = notable;
    %else %let label = critical;

    data &out;
        length target $32 label $10;
        target = "&target_col";
        dev_event_rate_pct = round(&dev_rate, 0.01);
        mon_event_rate_pct = round(&mon_rate, 0.01);
        delta_pp           = round(&delta_pp, 0.01);
        label              = "&label";
        output;
    run;
%mend drift_tech5_target;

%macro drift_tech6_distribution_stats(dev=, mon=, out=);
    %dq_tech1_profile(in_dataset=&dev, out=_dtd_devprof_);
    %dq_tech1_profile(in_dataset=&mon, out=_dtd_monprof_);

    proc sql;
        create table _dtd_joined_ as
        select d.name,
               d.type,
               d.cardinality_count as dev_cardinality, m.cardinality_count as mon_cardinality,
               d.min as dev_min, m.min as mon_min,
               d.max as dev_max, m.max as mon_max,
               d.std as dev_std, m.std as mon_std,
               d.mean as dev_mean, m.mean as mon_mean,
               d.kurtosis as dev_kurtosis, m.kurtosis as mon_kurtosis,
               d.q25 as dev_q25, d.q50 as dev_q50, d.q75 as dev_q75,
               m.q25 as mon_q25, m.q50 as mon_q50, m.q75 as mon_q75
        from _dtd_devprof_ d
        inner join _dtd_monprof_ m on upcase(d.name) = upcase(m.name)
        where d.type = 1;
    quit;

    data &out;
        set _dtd_joined_;

        if dev_cardinality > 0 then
            cardinality_pct_change = round((mon_cardinality - dev_cardinality) / dev_cardinality, 0.001);

        if dev_std > 0 then
            std_drift_pct = round((mon_std - dev_std) / dev_std, 0.001);

        if dev_mean ne 0 then dev_cv = round(dev_std / dev_mean, 4);
        if mon_mean ne 0 then mon_cv = round(mon_std / mon_mean, 4);
        if dev_cv not in (., 0) then cv_drift_pct = round((mon_cv - dev_cv) / dev_cv, 0.001);

        kurtosis_delta = round(mon_kurtosis - dev_kurtosis, 4);

        if (dev_q75 - dev_q25) > 0 then
            median_shift_iqr = round((mon_q50 - dev_q50) / (dev_q75 - dev_q25), 4);

        drop type;
    run;

    proc datasets lib=work nolist;
        delete _dtd_devprof_ _dtd_monprof_ _dtd_joined_;
    quit;
%mend drift_tech6_distribution_stats;

%macro drift_tech7_entropy(dev=, mon=, out=, categorical_cols=);
    %local nvars i v dev_n mon_n dev_h mon_h;
    %let nvars = %sysfunc(countw(&categorical_cols));

    data &out;
        length feature $32;
        dev_entropy = .; mon_entropy = .; entropy_delta = .;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&categorical_cols, &i);

        proc freq data=&dev noprint;
            tables &v / out=_ent_dev_(keep=&v count);
        run;
        proc freq data=&mon noprint;
            tables &v / out=_ent_mon_(keep=&v count);
        run;

        proc sql noprint;
            select sum(count) into :dev_n trimmed from _ent_dev_;
            select sum(count) into :mon_n trimmed from _ent_mon_;
        quit;

        data _ent_dev_calc_;
            set _ent_dev_;
            p = count / &dev_n;
            h_term = -p * log2(p);
        run;
        data _ent_mon_calc_;
            set _ent_mon_;
            p = count / &mon_n;
            h_term = -p * log2(p);
        run;

        proc sql noprint;
            select sum(h_term) into :dev_h trimmed from _ent_dev_calc_;
            select sum(h_term) into :mon_h trimmed from _ent_mon_calc_;
        quit;

        proc sql;
            insert into &out
            values("&v", %sysfunc(round(&dev_h,0.0001)), %sysfunc(round(&mon_h,0.0001)),
                   %sysfunc(round(%sysevalf(&mon_h - &dev_h),0.0001)));
        quit;
    %end;

    proc datasets lib=work nolist;
        delete _ent_dev_ _ent_mon_ _ent_dev_calc_ _ent_mon_calc_;
    quit;
%mend drift_tech7_entropy;

%macro drift_tech8_ks(dev=, mon=, out=, feature_cols=, ks_stable=0.10, ks_shift=0.20);
    %local nvars i v;
    %let nvars = %sysfunc(countw(&feature_cols));

    data &out;
        length feature $32 ks_statistic 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&feature_cols, &i);
        %_ks_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                          ks_stable=&ks_stable, ks_shift=&ks_shift);
    %end;
%mend drift_tech8_ks;

%macro _ks_one_feature(dev=, mon=, var=, out=, ks_stable=0.10, ks_shift=0.20);
    %local dmin dq25 dq50 dq75 dmax mmin mq25 mq50 mq75 mmax ks_stat ks_label;

    proc means data=&dev noprint;
        var &var;
        output out=_ksd_ min=min p25=q25 p50=q50 p75=q75 max=max;
    run;
    data _null_;
        set _ksd_;
        call symputx('dmin', min, 'L'); call symputx('dq25', q25, 'L');
        call symputx('dq50', q50, 'L'); call symputx('dq75', q75, 'L');
        call symputx('dmax', max, 'L');
    run;

    proc means data=&mon noprint;
        var &var;
        output out=_ksm_ min=min p25=q25 p50=q50 p75=q75 max=max;
    run;
    data _null_;
        set _ksm_;
        call symputx('mmin', min, 'L'); call symputx('mq25', q25, 'L');
        call symputx('mq50', q50, 'L'); call symputx('mq75', q75, 'L');
        call symputx('mmax', max, 'L');
    run;

    data _ks_calc_;
        array dpts{5} _temporary_ (&dmin &dq25 &dq50 &dq75 &dmax);
        array dcdf{5} _temporary_ (0 0.25 0.50 0.75 1.0);
        array mpts{5} _temporary_ (&mmin &mq25 &mq50 &mq75 &mmax);
        array mcdf{5} _temporary_ (0 0.25 0.50 0.75 1.0);
        array gap{5};

        do i = 1 to 5;
            x = dpts{i};
            if x <= mpts{1} then mon_cdf_at_x = 0;
            else if x >= mpts{5} then mon_cdf_at_x = 1;
            else do j = 1 to 4;
                if mpts{j} <= x <= mpts{j+1} then do;
                    if mpts{j+1} = mpts{j} then mon_cdf_at_x = mcdf{j};
                    else mon_cdf_at_x = mcdf{j} + (x - mpts{j}) / (mpts{j+1} - mpts{j}) * (mcdf{j+1} - mcdf{j});
                end;
            end;
            gap{i} = abs(mon_cdf_at_x - dcdf{i});
        end;

        ks_stat = max(of gap{*});
        output;
        keep ks_stat;
    run;

    proc sql noprint;
        select ks_stat into :ks_stat trimmed from _ks_calc_;
    quit;

    %if %sysevalf(&ks_stat < &ks_stable) %then %let ks_label = stable;
    %else %if %sysevalf(&ks_stat < &ks_shift) %then %let ks_label = monitor;
    %else %let ks_label = shift;

    proc sql;
        insert into &out
        values("&var", %sysfunc(round(&ks_stat, 0.0001)), "&ks_label");
    quit;

    proc datasets lib=work nolist;
        delete _ksd_ _ksm_ _ks_calc_;
    quit;
%mend _ks_one_feature;

%macro drift_tech9_categorical_psi(dev=, mon=, out=, categorical_cols=,
                                    psi_stable=0.10, psi_shift=0.25);
    %local nvars i v;
    %let nvars = %sysfunc(countw(&categorical_cols));

    data &out;
        length feature $32 psi 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&categorical_cols, &i);
        %_categorical_psi_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                                       psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;
%mend drift_tech9_categorical_psi;

%macro _categorical_psi_one_feature(dev=, mon=, var=, out=, psi_stable=0.10, psi_shift=0.25);
    %local dev_n mon_n psi_val psi_label;

    proc freq data=&dev noprint;
        tables &var / out=_catpsi_dev_(keep=&var count);
    run;
    proc freq data=&mon noprint;
        tables &var / out=_catpsi_mon_(keep=&var count);
    run;

    proc sql noprint;
        select sum(count) into :dev_n trimmed from _catpsi_dev_;
        select sum(count) into :mon_n trimmed from _catpsi_mon_;
    quit;

    proc sql;
        create table _catpsi_joined_ as
        select coalesce(d.&var, m.&var) as category,
               coalesce(d.count, 0) as dev_count,
               coalesce(m.count, 0) as mon_count
        from _catpsi_dev_ d
        full join _catpsi_mon_ m on d.&var = m.&var;
    quit;

    data _catpsi_calc_;
        set _catpsi_joined_;
        dev_pct = max(dev_count / &dev_n, 0.000001);
        mon_pct = max(mon_count / &mon_n, 0.000001);
        contrib = (mon_pct - dev_pct) * log(mon_pct / dev_pct);
    run;

    proc sql noprint;
        select sum(contrib) into :psi_val trimmed from _catpsi_calc_;
    quit;

    %if %sysevalf(&psi_val < &psi_stable) %then %let psi_label = stable;
    %else %if %sysevalf(&psi_val < &psi_shift) %then %let psi_label = monitor;
    %else %let psi_label = shift;

    proc sql;
        insert into &out
        values("&var", %sysfunc(round(&psi_val, 0.0001)), "&psi_label");
    quit;

    proc datasets lib=work nolist;
        delete _catpsi_dev_ _catpsi_mon_ _catpsi_joined_ _catpsi_calc_;
    quit;
%mend _categorical_psi_one_feature;


/* ============================================================================
   00_main_wrapper.sas
   ============================================================================ */
%macro main_wrapper(dev_dta=, mon_dta=,
                     is_dq_req=N, is_drift_req=N,
                     order=DQ_FIRST,
                     target_col=, score_col=, id_cols=, private_cols=, feature_cols=,
                     categorical_cols=,
                     missing_thresh=50, id_uniqueness_thresh=99.9, leakage_card_min=50,
                     psi_stable=0.10, psi_shift=0.25, ks_stable=0.10, ks_shift=0.20,
                     drift_notable=3, drift_critical=8);

    %macro _run_dq;
        %if &is_dq_req = Y %then %do;
            %put NOTE: ==== Running Data Quality: DEV ====;
            %dq_calc_wrapper(in_dataset=&dev_dta, out_prefix=dq_dev,
                              target_col=&target_col, id_cols=&id_cols,
                              private_cols=&private_cols,
                              missing_thresh=&missing_thresh,
                              id_uniqueness_thresh=&id_uniqueness_thresh,
                              leakage_card_min=&leakage_card_min);

            %put NOTE: ==== Running Data Quality: MONITORING ====;
            %dq_calc_wrapper(in_dataset=&mon_dta, out_prefix=dq_mon,
                              target_col=&target_col, id_cols=&id_cols,
                              private_cols=&private_cols,
                              missing_thresh=&missing_thresh,
                              id_uniqueness_thresh=&id_uniqueness_thresh,
                              leakage_card_min=&leakage_card_min);
        %end;
    %mend _run_dq;

    %macro _run_drift;
        %if &is_drift_req = Y %then %do;
            %put NOTE: ==== Running Drift Analysis: DEV vs MONITORING ====;
            %drift_calc_wrapper(dev_dataset=&dev_dta, mon_dataset=&mon_dta,
                                 out_prefix=drift, target_col=&target_col,
                                 score_col=&score_col, feature_cols=&feature_cols,
                                 categorical_cols=&categorical_cols,
                                 psi_stable=&psi_stable, psi_shift=&psi_shift,
                                 ks_stable=&ks_stable, ks_shift=&ks_shift);
        %end;
    %mend _run_drift;

    %if %upcase(&order) = DRIFT_FIRST %then %do;
        %_run_drift;
        %_run_dq;
    %end;
    %else %do;
        %_run_dq;
        %_run_drift;
    %end;

    %put NOTE: ==== main_wrapper complete. ====;
%mend main_wrapper;


/* ============================================================================
   RUN IT — using the CAS tables already loaded in the Public caslib
   ============================================================================ */
%main_wrapper(
    dev_dta       = public.v2_development_data,
    mon_dta       = public.v2_monitoring_2026_01,
    is_dq_req     = Y,
    is_drift_req  = Y,
    order         = DQ_FIRST,
    target_col    = default_flag,
    score_col     = pd_score,
    id_cols       = customer_id,
    private_cols     = age,
    feature_cols     = age annual_income bureau_score dti utilization ltv ead lgd_actual,
    categorical_cols = region employment_type industry
);

/* ---- Inspect results ---- */
title "DQ - Development data: blockers";
proc print data=work.dq_dev_blockers noobs; run;

title "DQ - Development data: governance flags";
proc print data=work.dq_dev_governance noobs; run;

title "DQ - Development data: health score & readiness";
proc print data=work.dq_dev_health noobs; run;

title "Drift - schema changes (dev vs mon)";
proc print data=work.drift_schema noobs;
    where change_type ne "unchanged";
run;

title "Drift - completeness drift";
proc print data=work.drift_completeness noobs; run;

title "Drift - CSI per feature";
proc print data=work.drift_csi noobs; run;

title "Drift - distribution stats (quantile/std/CV/boundary/kurtosis/cardinality)";
proc print data=work.drift_distribution noobs; run;

title "Drift - KS statistic per feature (approximate)";
proc print data=work.drift_ks noobs; run;

title "Drift - entropy drift (categorical columns)";
proc print data=work.drift_entropy noobs; run;

title "Drift - categorical PSI (region/employment_type/industry, real severity label)";
proc print data=work.drift_categorical_psi noobs; run;

title "Drift - score-level PSI (System Stability Index)";
proc print data=work.drift_score_psi noobs; run;

title "Drift - target/event-rate drift";
proc print data=work.drift_target noobs; run;
