/* ============================================================================
   drift_csi.sas
   (was %drift_tech3_csi in the old 20_drift_macros.sas)

   Characteristic Stability Index: PSI applied to each raw feature (dev vs
   mon), using real decile bins - exact, not approximated. Same formula as
   drift_score_psi.sas, different target.

   Requires (compiled first): drift_psi_one_feature.sas
   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_csi(dev=, mon=, out=, feature_cols=, psi_stable=0.10, psi_shift=0.25);

    %local nvars i v;
    %let nvars = %sysfunc(countw(&feature_cols));

    data &out;
        length feature $32 csi 8 label $10;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&feature_cols, &i);
        %drift_psi_one_feature(dev=&dev, mon=&mon, var=&v, out=&out,
                                name_col=feature, psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;

%mend drift_csi;
