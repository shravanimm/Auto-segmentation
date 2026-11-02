/* ============================================================================
   csb_segmentation_calc_wrapper.sas
   Entry point for auto-segmentation, the segmentation counterpart of
   csb_dq_dr_calc_wrapper. This is the macro a Cirrus-triggered job calls:
   inputs are two table references + plain macro parameters, outputs are WORK
   (or caller-library) tables with fixed names - no other coupling.

   techniques : space-separated subset of
       AUTOSLICER  DRIFT_TREE  GRADIENT_BOOSTING  KMEANS  FEATURE_BINNING
   Feature lists (space separated, in schema order):
       feature_cols      every legitimate feature (also the root-cause PSI list)
       numeric_cols      numeric features   \ used by the tree / cluster techniques
       categorical_cols  character features /  (build_feature_schema equivalent)
   Output tables, for each technique T with prefix
       AUTOSLICER -> &out_prefix._autoslicer      DRIFT_TREE -> &out_prefix._drifttree
       GRADIENT_BOOSTING -> &out_prefix._gradboost KMEANS -> &out_prefix._kmeans
       FEATURE_BINNING -> &out_prefix._featbin
     <prefix>_segments _rules _portfolio _feature_psi _pool _log
     (+ _selected_params for AutoSlicer, _k_diagnostics/_centroids/_encoding for
      K-Means; Feature Binning has no _portfolio)
   Cross-technique (when >= 1 technique returned segments):
       &out_prefix._combined   &out_prefix._cross_top10
   Run bookkeeping: &out_prefix._run_log (technique, status, message, seconds)

   Technique parameters are prefixed: as_ (AutoSlicer), dt_ (Drift Tree), gb_
   (Gradient Boosting), km_ (K-Means), fb_ (Feature Binning); defaults equal
   models/config.py. as_*_list parameters trigger the AutoSlicer grid search.
   A failed technique does not stop the others (status ERROR in the run log).
   ============================================================================ */
%macro csb_segmentation_calc_wrapper(dev_dta=, mon_dta=,
        techniques=AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
        target_col=, score_col=, weight_col=, feature_cols=, numeric_cols=, categorical_cols=,
        shap_cols=, top_n=10, min_events_per_slice=30, min_abs_count=, min_support=,
        significance_alpha=0.05, max_segment_pct=0.35, overlap_jaccard_threshold=0.70,
        rca_name_filter=Y,
        as_max_combo_depth=6, as_beam_width=30, as_numeric_bins=4,
        as_depth_list=, as_beam_list=, as_bins_list=,
        dt_max_depth=3, dt_min_samples_leaf=0.05,
        gb_n_estimators=100, gb_max_depth=3, gb_learning_rate=0.1, gb_min_samples_leaf=0.05,
        gb_max_trees_scanned=,
        km_k_min=2, km_k_max=12, km_min_cluster_pct=0.03, km_seed=42, km_max_tree_depth=4,
        km_drift_aware=Y, km_drift_weight=0.4, km_n_init=10,
        fb_max_features=30, fb_max_bins=8, fb_min_bin_pct=0.01, fb_top_n=20,
        fb_bootstrap_top_n=40, fb_n_iter=50, fb_alpha=0.10, fb_seed=42,
        out_prefix=seg);

    %local i t n t0 status msg ok prefixes pfx;
    %let prefixes = ;

    data &out_prefix._run_log;
        length technique $30 status $20 message $200 seconds 8;
        stop;
    run;

    %let n = %sysfunc(countw(&techniques, %str( )));
    %do i = 1 %to &n;
        %let t  = %upcase(%scan(&techniques, &i, %str( )));
        %let t0 = %sysfunc(datetime());
        %let status = OK;
        %let msg = ;
        %let syscc = 0;

        %if &t = AUTOSLICER %then %do;
            %let pfx = &out_prefix._autoslicer;
            %seg_autoslicer_grid(dev=&dev_dta, mon=&mon_dta, target_col=&target_col,
                score_col=&score_col, weight_col=&weight_col, feature_cols=&feature_cols,
                shap_cols=&shap_cols, depth_list=&as_depth_list, beam_list=&as_beam_list,
                bins_list=&as_bins_list, max_combo_depth=&as_max_combo_depth,
                beam_width=&as_beam_width, numeric_bins=&as_numeric_bins, top_n=&top_n,
                min_events_per_slice=&min_events_per_slice, min_abs_count=&min_abs_count,
                min_support=&min_support, significance_alpha=&significance_alpha,
                max_segment_pct=&max_segment_pct,
                overlap_jaccard_threshold=&overlap_jaccard_threshold,
                rca_name_filter=&rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = DRIFT_TREE %then %do;
            %let pfx = &out_prefix._drifttree;
            %seg_drift_tree(dev=&dev_dta, mon=&mon_dta, target_col=&target_col, score_col=&score_col,
                weight_col=&weight_col, feature_cols=&feature_cols, numeric_cols=&numeric_cols,
                categorical_cols=&categorical_cols, shap_cols=&shap_cols,
                max_depth=&dt_max_depth, min_samples_leaf=&dt_min_samples_leaf, top_n=&top_n,
                min_events_per_slice=&min_events_per_slice, min_abs_count=&min_abs_count,
                min_support=&min_support, significance_alpha=&significance_alpha,
                max_segment_pct=&max_segment_pct, rca_name_filter=&rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = GRADIENT_BOOSTING %then %do;
            %let pfx = &out_prefix._gradboost;
            %seg_gradient_boosting(dev=&dev_dta, mon=&mon_dta, target_col=&target_col,
                score_col=&score_col, weight_col=&weight_col, numeric_cols=&numeric_cols,
                categorical_cols=&categorical_cols, shap_cols=&shap_cols,
                n_estimators=&gb_n_estimators, max_depth=&gb_max_depth,
                learning_rate=&gb_learning_rate, min_samples_leaf=&gb_min_samples_leaf,
                max_trees_scanned=&gb_max_trees_scanned, top_n=&top_n,
                min_events_per_slice=&min_events_per_slice, min_abs_count=&min_abs_count,
                min_support=&min_support, significance_alpha=&significance_alpha,
                max_segment_pct=&max_segment_pct,
                overlap_jaccard_threshold=&overlap_jaccard_threshold,
                rca_name_filter=&rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = KMEANS %then %do;
            %let pfx = &out_prefix._kmeans;
            %seg_kmeans(dev=&dev_dta, mon=&mon_dta, target_col=&target_col, score_col=&score_col,
                weight_col=&weight_col, feature_cols=&feature_cols, numeric_cols=&numeric_cols,
                categorical_cols=&categorical_cols, shap_cols=&shap_cols,
                k_min=&km_k_min, k_max=&km_k_max, min_cluster_pct=&km_min_cluster_pct,
                seed=&km_seed, max_tree_depth=&km_max_tree_depth, drift_aware=&km_drift_aware,
                drift_weight=&km_drift_weight, n_init=&km_n_init, top_n=&top_n,
                min_events_per_slice=&min_events_per_slice, min_abs_count=&min_abs_count,
                min_support=&min_support, significance_alpha=&significance_alpha,
                max_segment_pct=&max_segment_pct, rca_name_filter=&rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = FEATURE_BINNING %then %do;
            %let pfx = &out_prefix._featbin;
            %seg_feature_binning(dev=&dev_dta, mon=&mon_dta, target_col=&target_col,
                score_col=&score_col, weight_col=&weight_col, feature_cols=&feature_cols,
                shap_cols=&shap_cols, max_features=&fb_max_features, max_bins=&fb_max_bins,
                min_bin_pct=&fb_min_bin_pct, max_segment_pct=&max_segment_pct,
                overlap_jaccard_threshold=&overlap_jaccard_threshold, top_n=&fb_top_n,
                bootstrap_top_n=&fb_bootstrap_top_n, n_iter=&fb_n_iter, alpha=&fb_alpha,
                seed=&fb_seed, rca_name_filter=&rca_name_filter, out_prefix=&pfx);
        %end;
        %else %do;
            %let pfx = ;
            %let status = NOT_RUN;
            %let msg = Unknown technique name;
            %put WARNING: csb_segmentation_calc_wrapper - unknown technique &t..;
        %end;

        %if &status = OK %then %do;
            %if &syscc > 4 %then %do;
                %let status = ERROR;
                %let msg = See log (SYSCC=&syscc);
            %end;
            %else %if %length(&pfx) %then %let prefixes = &prefixes &pfx;
        %end;

        proc sql;
            insert into &out_prefix._run_log
            values("&t", "&status", "&msg", %sysevalf(%sysfunc(datetime()) - &t0));
        quit;
    %end;

    %if %length(&prefixes) %then %do;
        %seg_cross_technique(prefixes=&prefixes, out_prefix=&out_prefix);
    %end;

    %put NOTE: csb_segmentation_calc_wrapper complete - see &out_prefix._run_log;

%mend csb_segmentation_calc_wrapper;
