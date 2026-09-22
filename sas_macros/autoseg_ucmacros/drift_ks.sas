/* ============================================================================
   drift_ks.sas
   (was %drift_tech8_ks in the old 20_drift_macros.sas)

   Approximate KS statistic per feature - see drift_ks_one_feature.sas for
   the method and why it is deliberately approximate.

   Requires (compiled first): drift_ks_one_feature.sas
   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_ks(dev=, mon=, out=, feature_cols=, ks_stable=0.10, ks_shift=0.20);

    %local nvars i v;
    %let nvars = %sysfunc(countw(&feature_cols));

    data &out;
        length feature $32 ks_statistic 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&feature_cols, &i);
        %drift_ks_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                               ks_stable=&ks_stable, ks_shift=&ks_shift);
    %end;

%mend drift_ks;
