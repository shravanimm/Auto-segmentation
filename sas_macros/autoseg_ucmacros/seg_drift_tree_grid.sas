/* ============================================================================
   seg_drift_tree_grid.sas
   AUTO-OPTIMISATION for the Drift Localization Tree: one run per tree depth in
   depth_list; the winner is chosen by the rule in seg_grid.sas.
   ============================================================================ */
%macro seg_drift_tree_grid(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=,
                           numeric_cols=, categorical_cols=, shap_cols=, depth_list=, min_samples_leaf=0.05,
                           top_n=10, min_events_per_slice=30, min_abs_count=, min_support=,
                           significance_alpha=0.05, max_segment_pct=0.35, rca_name_filter=Y,
                           out_prefix=seg_dt);

    %local n a k best bestk sc da;
    %let n = %sysfunc(countw(&depth_list, %str( )));
    %let k = 0;
    %let best = -1E30;
    %let bestk = 0;
    %seg_grid_begin;

    %do a = 1 %to &n;
        %let k  = %eval(&k + 1);
        %let da = %scan(&depth_list, &a, %str( ));

        %seg_drift_tree(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
            weight_col=&weight_col, feature_cols=&feature_cols, numeric_cols=&numeric_cols,
            categorical_cols=&categorical_cols, shap_cols=&shap_cols, max_depth=&da,
            min_samples_leaf=&min_samples_leaf, top_n=&top_n, min_events_per_slice=&min_events_per_slice,
            min_abs_count=&min_abs_count, min_support=&min_support, significance_alpha=&significance_alpha,
            max_segment_pct=&max_segment_pct, rca_name_filter=&rca_name_filter, out_prefix=sgr&k);

        %seg_grid_score(seg=sgr&k._segments, tech=Drift Localization Tree, combo=&k,
                        params=max_depth=&da, into=sc);

        %if %sysevalf(&sc > &best) %then %do;
            %let best  = &sc;
            %let bestk = &k;
        %end;
    %end;

    %seg_grid_publish(best=&bestk, out_prefix=&out_prefix);

%mend seg_drift_tree_grid;
