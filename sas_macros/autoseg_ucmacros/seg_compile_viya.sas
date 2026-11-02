/* ============================================================================
   seg_compile.sas
   Compiles every segmentation macro in this folder (macro definitions only -
   nothing executes). Same pattern as dq_dr_compile.sas.

   Requires the caller to set the segmac folder to this folder's path:
       %let _autoseg_ucmacros = /path/to/sas_macros/autoseg_ucmacros;
       %include segmac(seg_compile.sas);

   SAS Viya / SAS Content alternative (one fileref per folder, then %include the
   members you need or this file):
       filename segmac filesrvc folderpath="/Public/AutoSegmentation/autoseg_ucmacros";
       %include segmac(seg_compile.sas);
   Base SAS only: Compute server, no CAS, no VDMML/SAS Risk licences needed.
   ============================================================================ */

/* ---- small utilities ---- */
%include segmac(seg_nobs.sas);
%include segmac(seg_vartype.sas);
%include segmac(seg_fmtnum.sas);
%include segmac(seg_fix_case.sas);
%include segmac(seg_f32.sas);
%include segmac(seg_quantile_t7_by.sas);

/* ---- shared engine (all techniques) ---- */
%include segmac(seg_prep.sas);
%include segmac(seg_membership.sas);
%include segmac(seg_candidate_filter.sas);
%include segmac(seg_cand_rules.sas);
%include segmac(seg_auc_ks.sas);
%include segmac(seg_ks_shift.sas);
%include segmac(seg_feature_psi.sas);
%include segmac(seg_shap_shift.sas);
%include segmac(seg_evaluate_candidates.sas);
%include segmac(seg_bh.sas);
%include segmac(seg_score_candidates.sas);
%include segmac(seg_rank_dedup.sas);
%include segmac(seg_eval_pool.sas);
%include segmac(seg_publish.sas);

/* ---- CART engine (Drift Tree, Gradient Boosting, K-Means rules) ---- */
%include segmac(seg_tree_matrix.sas);
%include segmac(seg_tree_presort.sas);
%include segmac(seg_tree_fit.sas);
%include segmac(seg_tree_rules.sas);

/* ---- AutoSlicer ---- */
%include segmac(seg_as_pred_num.sas);
%include segmac(seg_as_pred_cat.sas);
%include segmac(seg_as_predicates.sas);
%include segmac(seg_as_step.sas);
%include segmac(seg_autoslicer.sas);
%include segmac(seg_autoslicer_grid.sas);

/* ---- Drift Tree / Gradient Boosting ---- */
%include segmac(seg_drift_tree.sas);
%include segmac(seg_gradient_boosting.sas);

/* ---- K-Means ---- */
%include segmac(seg_km_encode.sas);
%include segmac(seg_km_fit.sas);
%include segmac(seg_km_predict.sas);
%include segmac(seg_km_metrics.sas);
%include segmac(seg_km_select_k.sas);
%include segmac(seg_kmeans.sas);

/* ---- Feature Binning ---- */
%include segmac(seg_fb_strength.sas);
%include segmac(seg_fb_bins_num.sas);
%include segmac(seg_fb_bins_cat.sas);
%include segmac(seg_fb_membership.sas);
%include segmac(seg_fb_calib.sas);
%include segmac(seg_fb_bootstrap.sas);
%include segmac(seg_fb_score.sas);
%include segmac(seg_feature_binning.sas);

/* ---- cross-technique, entry point, parity tooling ---- */
%include segmac(seg_cross_technique.sas);
%include segmac(csb_segmentation_calc_wrapper.sas);
%include segmac(seg_compare_to_golden.sas);

%put NOTE: All segmentation macros compiled from the segmac folder;
