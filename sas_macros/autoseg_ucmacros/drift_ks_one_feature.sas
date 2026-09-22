/* ============================================================================
   drift_ks_one_feature.sas
   (was the helper %_ks_one_feature in the old 20_drift_macros.sas)

   Approximate Kolmogorov-Smirnov statistic for one feature: max gap between
   the two cumulative distributions, checked at the 5 quantile checkpoints
   (min/Q1/median/Q3/max) built from the DEV data. This mirrors the EDA
   project's ks_approx method deliberately - a true two-sample KS test in SAS
   (PROC NPAR1WAY EDF) is a real follow-up, but its exact ODS table/column
   names need to be confirmed against a live session before shipping. This
   approximate version is known-safe.

   Called by: drift_ks.sas
   ============================================================================ */
%macro drift_ks_one_feature(dev=, mon=, var=, out=, ks_stable=0.10, ks_shift=0.20);

    %local dmin dq25 dq50 dq75 dmax
           mmin mq25 mq50 mq75 mmax
           ks_stat ks_label;

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

    /* dev CDF is fixed at [0, .25, .50, .75, 1.0] at its own checkpoints.
       Approximate mon's CDF value at each of dev's checkpoints by linear
       interpolation across mon's own 5 known points, then take the max gap. */
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

%mend drift_ks_one_feature;
