/* ============================================================================
   drift_target_bad_rate.sas
   (was %drift_tech5_target in the old 20_drift_macros.sas)

   Event-rate / bad-rate shift, dev vs mon. Assumes target_col is a 0/1
   numeric flag.

   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_target_bad_rate(dev=, mon=, out=, target_col=, drift_notable=3, drift_critical=8);

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

%mend drift_target_bad_rate;
