/* ============================================================================
   seg_compile.sas
   Compiles every segmentation macro in this folder (macro definitions only -
   nothing executes). Same pattern as dq_dr_compile.sas.

   Requires the caller to set &_autoseg_ucmacros to this folder's path:
       %let _autoseg_ucmacros = /path/to/sas_macros/autoseg_ucmacros;
       %include "&_autoseg_ucmacros/seg_compile.sas";

   SAS Viya / SAS Content alternative (one fileref per folder, then %include the
   members you need or this file):
       filename segmac filesrvc folderpath="/Public/AutoSegmentation/autoseg_ucmacros";
       %include segmac(seg_compile.sas);
   Base SAS only: Compute server, no CAS, no VDMML/SAS Risk licences needed.
   ============================================================================ */

/* ---- small utilities ---- */
%include "&_autoseg_ucmacros/seg_nobs.sas";
%include "&_autoseg_ucmacros/seg_vartype.sas";
%include "&_autoseg_ucmacros/seg_fmtnum.sas";
%include "&_autoseg_ucmacros/seg_fix_case.sas";
%include "&_autoseg_ucmacros/seg_f32.sas";
%include "&_autoseg_ucmacros/seg_quantile_t7_by.sas";

/* ---- shared engine (all techniques) ---- */
%include "&_autoseg_ucmacros/seg_prep.sas";
%include "&_autoseg_ucmacros/seg_membership.sas";
%include "&_autoseg_ucmacros/seg_candidate_filter.sas";
%include "&_autoseg_ucmacros/seg_cand_rules.sas";
%include "&_autoseg_ucmacros/seg_auc_ks.sas";
%include "&_autoseg_ucmacros/seg_ks_shift.sas";
%include "&_autoseg_ucmacros/seg_feature_psi.sas";
%include "&_autoseg_ucmacros/seg_shap_shift.sas";
%include "&_autoseg_ucmacros/seg_evaluate_candidates.sas";
%include "&_autoseg_ucmacros/seg_bh.sas";
%include "&_autoseg_ucmacros/seg_score_candidates.sas";
%include "&_autoseg_ucmacros/seg_rank_dedup.sas";
%include "&_autoseg_ucmacros/seg_eval_pool.sas";
%include "&_autoseg_ucmacros/seg_publish.sas";

/* ---- CART engine (Drift Tree, Gradient Boosting, K-Means rules) ---- */
%include "&_autoseg_ucmacros/seg_tree_matrix.sas";
%include "&_autoseg_ucmacros/seg_tree_presort.sas";
%include "&_autoseg_ucmacros/seg_tree_fit.sas";
%include "&_autoseg_ucmacros/seg_tree_rules.sas";

/* ---- AutoSlicer ---- */
%include "&_autoseg_ucmacros/seg_as_pred_num.sas";
%include "&_autoseg_ucmacros/seg_as_pred_cat.sas";
%include "&_autoseg_ucmacros/seg_as_predicates.sas";
%include "&_autoseg_ucmacros/seg_as_step.sas";
%include "&_autoseg_ucmacros/seg_autoslicer.sas";
%include "&_autoseg_ucmacros/seg_autoslicer_grid.sas";

/* ---- Drift Tree / Gradient Boosting ---- */
%include "&_autoseg_ucmacros/seg_drift_tree.sas";
%include "&_autoseg_ucmacros/seg_gradient_boosting.sas";

/* ---- K-Means ---- */
%include "&_autoseg_ucmacros/seg_km_encode.sas";
%include "&_autoseg_ucmacros/seg_km_fit.sas";
%include "&_autoseg_ucmacros/seg_km_predict.sas";
%include "&_autoseg_ucmacros/seg_km_metrics.sas";
%include "&_autoseg_ucmacros/seg_km_select_k.sas";
%include "&_autoseg_ucmacros/seg_kmeans.sas";

/* ---- Feature Binning ---- */
%include "&_autoseg_ucmacros/seg_fb_strength.sas";
%include "&_autoseg_ucmacros/seg_fb_bins_num.sas";
%include "&_autoseg_ucmacros/seg_fb_bins_cat.sas";
%include "&_autoseg_ucmacros/seg_fb_membership.sas";
%include "&_autoseg_ucmacros/seg_fb_calib.sas";
%include "&_autoseg_ucmacros/seg_fb_bootstrap.sas";
%include "&_autoseg_ucmacros/seg_fb_score.sas";
%include "&_autoseg_ucmacros/seg_feature_binning.sas";

/* ---- cross-technique, entry point, parity tooling ---- */
%include "&_autoseg_ucmacros/seg_cross_technique.sas";
%include "&_autoseg_ucmacros/csb_segmentation_calc_wrapper.sas";
%include "&_autoseg_ucmacros/seg_compare_to_golden.sas";

%put NOTE: All segmentation macros compiled from &_autoseg_ucmacros;
