/* ============================================================================
   drift_completeness.sas
   (was %drift_tech2_completeness in the old 20_drift_macros.sas)

   Missing% delta per column, both versions present. pp = percentage points.

   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_completeness(dev=, mon=, out=, delta_alert=5);

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

%mend drift_completeness;
