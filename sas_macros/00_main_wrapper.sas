/* ============================================================================
   00_main_wrapper.sas
   Top-level entry point — matches the wrapper pattern from the example
   given (is_dq_req / is_drift_req flags, conditional %do blocks).

   Order flexibility: &order controls which stage runs first. Since neither
   stage depends on the output of the other (both work directly off dev_dta /
   mon_dta), this is just a matter of which %if branch runs first — no
   real parallel execution attempted here (see the "no parallel processing
   in base SAS macros" note from the design discussion).

   Requires (%include, in order): 10_dq_macros.sas, 20_drift_macros.sas
   ============================================================================ */

%macro main_wrapper(dev_dta=, mon_dta=,
                     is_dq_req=N, is_drift_req=N,
                     order=DQ_FIRST,           /* DQ_FIRST | DRIFT_FIRST */
                     target_col=, score_col=, id_cols=, private_cols=, feature_cols=,
                     categorical_cols=,
                     missing_thresh=50, id_uniqueness_thresh=99.9, leakage_card_min=50,
                     psi_stable=0.10, psi_shift=0.25, ks_stable=0.10, ks_shift=0.20,
                     drift_notable=3, drift_critical=8);

    %macro _run_dq;
        %if &is_dq_req = Y %then %do;
            %put NOTE: ==== Running Data Quality: DEV ====;
            %dq_calc_wrapper(in_dataset=&dev_dta, out_prefix=dq_dev,
                              target_col=&target_col, id_cols=&id_cols,
                              private_cols=&private_cols,
                              missing_thresh=&missing_thresh,
                              id_uniqueness_thresh=&id_uniqueness_thresh,
                              leakage_card_min=&leakage_card_min);

            %put NOTE: ==== Running Data Quality: MONITORING ====;
            %dq_calc_wrapper(in_dataset=&mon_dta, out_prefix=dq_mon,
                              target_col=&target_col, id_cols=&id_cols,
                              private_cols=&private_cols,
                              missing_thresh=&missing_thresh,
                              id_uniqueness_thresh=&id_uniqueness_thresh,
                              leakage_card_min=&leakage_card_min);
        %end;
    %mend _run_dq;

    %macro _run_drift;
        %if &is_drift_req = Y %then %do;
            %put NOTE: ==== Running Drift Analysis: DEV vs MONITORING ====;
            %drift_calc_wrapper(dev_dataset=&dev_dta, mon_dataset=&mon_dta,
                                 out_prefix=drift, target_col=&target_col,
                                 score_col=&score_col, feature_cols=&feature_cols,
                                 categorical_cols=&categorical_cols,
                                 psi_stable=&psi_stable, psi_shift=&psi_shift,
                                 ks_stable=&ks_stable, ks_shift=&ks_shift);
        %end;
    %mend _run_drift;

    %if %upcase(&order) = DRIFT_FIRST %then %do;
        %_run_drift;
        %_run_dq;
    %end;
    %else %do;
        %_run_dq;
        %_run_drift;
    %end;

    %put NOTE: ==== main_wrapper complete. Output tables (in WORK): ====;
    %if &is_dq_req = Y %then
        %put NOTE:   dq_dev_profile / _blockers / _governance / _health;
        %put NOTE:   dq_mon_profile / _blockers / _governance / _health;
    %if &is_drift_req = Y %then %do;
        %put NOTE:   drift_schema  drift_completeness  drift_csi  drift_distribution  drift_ks;
        %put NOTE:   drift_score_psi  drift_target  drift_entropy  drift_categorical_psi;
    %end;

%mend main_wrapper;
