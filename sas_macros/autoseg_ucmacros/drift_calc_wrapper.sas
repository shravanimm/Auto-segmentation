/* ============================================================================
   drift_calc_wrapper.sas
   Orchestrates the 9 drift techniques, dev vs mon. Our own logic (not ported
   from EDA): schema drift, completeness drift, per-feature PSI (CSI), score-
   level PSI (System Stability Index), and target/event-rate drift. All
   computed from the real dev/monitoring data directly - no quantile-
   approximation needed, since we have the actual rows (unlike the EDA
   project, which is metadata-only).

   feature_cols: space-separated list of columns to run CSI on (exclude
                 target/score/id columns - pass schema-detected feature list).

   Requires (compiled first): drift_schema.sas, drift_completeness.sas,
     drift_psi_one_feature.sas, drift_csi.sas, drift_score_psi.sas,
     drift_target_bad_rate.sas, dq_foundational_profiling.sas,
     drift_distribution_stats.sas, drift_entropy.sas, drift_ks_one_feature.sas,
     drift_ks.sas, drift_categorical_psi_one_feature.sas, drift_categorical_psi.sas
   Called by: csb_dq_dr_calc_wrapper.sas
   ============================================================================ */
%macro drift_calc_wrapper(dev_dataset=, mon_dataset=, out_prefix=drift,
                           target_col=, score_col=, feature_cols=, categorical_cols=,
                           psi_stable=0.10, psi_shift=0.25, ks_stable=0.10, ks_shift=0.20);

    %drift_schema(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._schema);

    %drift_completeness(dev=&dev_dataset, mon=&mon_dataset,
                         out=&out_prefix._completeness);

    %if %length(&feature_cols) %then %do;
        %drift_csi(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._csi,
                   feature_cols=&feature_cols,
                   psi_stable=&psi_stable, psi_shift=&psi_shift);

        %drift_distribution_stats(dev=&dev_dataset, mon=&mon_dataset,
                                   out=&out_prefix._distribution);

        %drift_ks(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._ks,
                  feature_cols=&feature_cols, ks_stable=&ks_stable, ks_shift=&ks_shift);
    %end;

    %if %length(&score_col) %then %do;
        %drift_score_psi(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._score_psi,
                          score_col=&score_col,
                          psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;

    %if %length(&target_col) %then %do;
        %drift_target_bad_rate(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._target,
                                target_col=&target_col);
    %end;

    %if %length(&categorical_cols) %then %do;
        %drift_entropy(dev=&dev_dataset, mon=&mon_dataset, out=&out_prefix._entropy,
                        categorical_cols=&categorical_cols);

        %drift_categorical_psi(dev=&dev_dataset, mon=&mon_dataset,
                                out=&out_prefix._categorical_psi,
                                categorical_cols=&categorical_cols,
                                psi_stable=&psi_stable, psi_shift=&psi_shift);
    %end;

    %put NOTE: Drift analysis complete: &dev_dataset vs &mon_dataset -> &out_prefix._*;

%mend drift_calc_wrapper;
