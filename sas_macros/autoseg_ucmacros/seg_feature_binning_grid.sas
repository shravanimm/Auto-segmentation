/* ============================================================================
   seg_feature_binning_grid.sas
   AUTO-OPTIMISATION for Feature Binning: one run per combination of maximum bins
   (bins_list) x smallest bin share (minbin_list); winner by the rule in seg_grid.sas.
   ============================================================================ */
%macro seg_feature_binning_grid(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                                bins_list=, minbin_list=, max_features=30, max_segment_pct=0.35,
                                overlap_jaccard_threshold=0.70, top_n=20, bootstrap_top_n=40,
                                n_iter=50, alpha=0.10, seed=42, rca_name_filter=Y, out_prefix=seg_fb);

    %local na nb a b k best bestk sc da db;
    %let na = %sysfunc(countw(&bins_list, %str( )));
    %let nb = %sysfunc(countw(&minbin_list, %str( )));
    %let k = 0;
    %let best = -1E30;
    %let bestk = 0;
    %seg_grid_begin;

    %do a = 1 %to &na;
      %do b = 1 %to &nb;
        %let k  = %eval(&k + 1);
        %let da = %scan(&bins_list, &a, %str( ));
        %let db = %scan(&minbin_list, &b, %str( ));

        %seg_feature_binning(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
            weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
            max_features=&max_features, max_bins=&da, min_bin_pct=&db, max_segment_pct=&max_segment_pct,
            overlap_jaccard_threshold=&overlap_jaccard_threshold, top_n=&top_n,
            bootstrap_top_n=&bootstrap_top_n, n_iter=&n_iter, alpha=&alpha, seed=&seed,
            rca_name_filter=&rca_name_filter, out_prefix=sgr&k);

        %seg_grid_score(seg=sgr&k._segments, tech=Feature Binning, combo=&k,
                        params=max_bins=&da min_bin_pct=&db, into=sc);

        %if %sysevalf(&sc > &best) %then %do;
            %let best  = &sc;
            %let bestk = &k;
        %end;
      %end;
    %end;

    %seg_grid_publish(best=&bestk, out_prefix=&out_prefix);

%mend seg_feature_binning_grid;
