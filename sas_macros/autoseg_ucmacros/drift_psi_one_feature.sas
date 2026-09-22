/* ============================================================================
   drift_psi_one_feature.sas
   (was the shared helper %_psi_one_feature in the old 20_drift_macros.sas)

   Real 10-bucket PSI for one numeric variable. Buckets are built from the DEV
   data's own decile boundaries (PROC RANK groups=10), then both dev and mon
   rows are counted into those same fixed boundaries - this is the real PSI,
   no distribution reconstruction/approximation involved.
   Appends one row (name, psi, label) into &out.

   Called by: drift_csi.sas, drift_score_psi.sas
   ============================================================================ */
%macro drift_psi_one_feature(dev=, mon=, var=, out=, name_col=feature,
                              psi_stable=0.10, psi_shift=0.25);

    proc rank data=&dev groups=10 out=_psi_devrank_(keep=&var _bucket_);
        var &var;
        ranks _bucket_;
    run;

    /* Build 9 interior cut points from the dev data own decile boundaries */
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

%mend drift_psi_one_feature;
