/* ============================================================================
   dq_calc_wrapper.sas
   Orchestrates the 4 DQ macros for one dataset: profile -> blockers ->
   governance -> health score.

   Requires (compiled first): dq_foundational_profiling.sas, dq_blockers.sas,
                               dq_governance.sas, dq_healthscore.sas
   Called by: csb_dq_dr_calc_wrapper.sas
   ============================================================================ */
%macro dq_calc_wrapper(in_dataset=, out_prefix=, target_col=, id_cols=, private_cols=,
                        missing_thresh=50, id_uniqueness_thresh=99.9, leakage_card_min=50);

    %dq_foundational_profiling(in_dataset=&in_dataset, out=&out_prefix._profile);

    %dq_blockers(profile=&out_prefix._profile, out=&out_prefix._blockers,
                 missing_thresh=&missing_thresh);

    %dq_governance(profile=&out_prefix._profile, out=&out_prefix._governance,
                   id_cols=&id_cols, private_cols=&private_cols, target_col=&target_col,
                   id_uniqueness_thresh=&id_uniqueness_thresh,
                   leakage_card_min=&leakage_card_min);

    %dq_healthscore(profile=&out_prefix._profile, blockers=&out_prefix._blockers,
                     governance=&out_prefix._governance, out=&out_prefix._health);

    %put NOTE: DQ complete for &in_dataset -> &out_prefix._profile / _blockers / _governance / _health;

%mend dq_calc_wrapper;
