/* ============================================================================
   drift_categorical_psi_one_feature.sas
   (was the helper %_categorical_psi_one_feature in the old 20_drift_macros.sas)

   Same PSI formula and the same stable/monitor/shift thresholds as
   drift_psi_one_feature.sas, but for categorical columns: buckets are the
   actual category values (via PROC FREQ, full outer join on the union of
   categories from both periods) instead of deciles.

   Called by: drift_categorical_psi.sas
   ============================================================================ */
%macro drift_categorical_psi_one_feature(dev=, mon=, var=, out=, psi_stable=0.10, psi_shift=0.25);

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

    /* full outer join on the category value - union of categories from both
       sides, so a category that appeared in only one period is not dropped */
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

%mend drift_categorical_psi_one_feature;
