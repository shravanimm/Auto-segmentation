/* ============================================================================
   seg_autoslicer_grid.sas
   AUTO-OPTIMISATION for AutoSlicer: run every combination of depth_list x beam_list x
   bins_list (itertools.product order, bins varies fastest) and keep the best by the
   rule in seg_grid.sas. One combination in each list = a plain run.
   Outputs: &out_prefix._* (the winner's tables) and &out_prefix._param_search.
   ============================================================================ */
%macro seg_autoslicer_grid(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                           depth_list=, beam_list=, bins_list=,
                           min_beam_width=8, beam_retain_ratio=0.5, depth_improvement_tolerance=0.05,
                           top_n=10, min_events_per_slice=30, min_abs_count=, min_support=,
                           significance_alpha=0.05, max_segment_pct=0.35,
                           overlap_jaccard_threshold=0.70, rca_name_filter=Y, out_prefix=seg_as);

    %local na nb nc a b c k best bestk sc da db dc;

    %let na = %sysfunc(countw(&depth_list, %str( )));
    %let nb = %sysfunc(countw(&beam_list,  %str( )));
    %let nc = %sysfunc(countw(&bins_list,  %str( )));
    %let k = 0;
    %let best = -1E30;
    %let bestk = 0;
    %seg_grid_begin;

    %do a = 1 %to &na;
      %do b = 1 %to &nb;
        %do c = 1 %to &nc;
            %let k  = %eval(&k + 1);
            %let da = %scan(&depth_list, &a, %str( ));
            %let db = %scan(&beam_list,  &b, %str( ));
            %let dc = %scan(&bins_list,  &c, %str( ));

            %seg_autoslicer(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
                weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
                max_combo_depth=&da, beam_width=&db, numeric_bins=&dc,
                min_beam_width=&min_beam_width, beam_retain_ratio=&beam_retain_ratio,
                depth_improvement_tolerance=&depth_improvement_tolerance, top_n=&top_n,
                min_events_per_slice=&min_events_per_slice, min_abs_count=&min_abs_count,
                min_support=&min_support, significance_alpha=&significance_alpha,
                max_segment_pct=&max_segment_pct,
                overlap_jaccard_threshold=&overlap_jaccard_threshold,
                rca_name_filter=&rca_name_filter, out_prefix=sgr&k);

            %seg_grid_score(seg=sgr&k._segments, tech=AutoSlicer, combo=&k,
                            params=max_combo_depth=&da beam_width=&db numeric_bins=&dc, into=sc);

            %if %sysevalf(&sc > &best) %then %do;
                %let best  = &sc;
                %let bestk = &k;
            %end;
        %end;
      %end;
    %end;

    %seg_grid_publish(best=&bestk, out_prefix=&out_prefix);

%mend seg_autoslicer_grid;
