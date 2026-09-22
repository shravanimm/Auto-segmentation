/* ============================================================================
   drift_categorical_psi.sas
   (was %drift_tech9_categorical_psi in the old 20_drift_macros.sas)

   The same PSI formula and thresholds as drift_csi.sas, but for categorical
   columns - see drift_categorical_psi_one_feature.sas for the per-feature
   calculation.

   Requires (compiled first): drift_categorical_psi_one_feature.sas
   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_categorical_psi(dev=, mon=, out=, categorical_cols=,
                              psi_stable=0.10, psi_shift=0.25);

    %local nvars i v;
    %let nvars = %sysfunc(countw(&categorical_cols));

    data &out;
        length feature $32 psi 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&categorical_cols, &i);
        %drift_categorical_psi_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                                            psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;

%mend drift_categorical_psi;
