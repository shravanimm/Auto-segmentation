/* ============================================================================
   drift_score_psi.sas
   (was %drift_tech4_score_psi in the old 20_drift_macros.sas)

   Same PSI formula as drift_csi.sas, applied once to the model score column
   (whole population) - the "System Stability Index".

   Requires (compiled first): drift_psi_one_feature.sas
   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_score_psi(dev=, mon=, out=, score_col=, psi_stable=0.10, psi_shift=0.25);

    data _score_psi_raw_;
        length feature $32 csi 8 label $10;
        stop;
    run;

    %drift_psi_one_feature(dev=&dev, mon=&mon, var=&score_col, out=_score_psi_raw_,
                            name_col=feature, psi_stable=&psi_stable, psi_shift=&psi_shift);

    proc sql;
        create table &out as
        select feature as score_column, csi as psi, label
        from _score_psi_raw_;
    quit;

    proc datasets lib=work nolist;
        delete _score_psi_raw_;
    quit;

%mend drift_score_psi;
