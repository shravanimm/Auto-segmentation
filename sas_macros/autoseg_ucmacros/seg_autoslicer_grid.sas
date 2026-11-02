/* ============================================================================
   seg_autoslicer_grid.sas
   Port of core/parameter_optimization.optimize_parameters for AutoSlicer: run
   every combination of depth_list x beam_list x bins_list, score each run by
   the SUM of Business_Impact_Score over its returned top-N segments, keep the
   first run with the strictly highest sum (Python: `score > best_score`).
   Combination order = itertools.product (bins varies fastest).
   A list left empty falls back to the single-value parameter, so one combination
   means a plain run. Writes the winner to &out_prefix._* plus
   &out_prefix._selected_params (the chosen values and the optimisation score).
   ============================================================================ */
%macro seg_autoslicer_grid(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                           depth_list=, beam_list=, bins_list=,
                           max_combo_depth=6, beam_width=30, numeric_bins=4,
                           min_beam_width=8, beam_retain_ratio=0.5, depth_improvement_tolerance=0.05,
                           top_n=10, min_events_per_slice=30, min_abs_count=, min_support=,
                           significance_alpha=0.05, max_segment_pct=0.35,
                           overlap_jaccard_threshold=0.70, rca_name_filter=Y, out_prefix=seg_as);

    %local na nb nc a b c k best bestk sc da db dc s sfx bd bb bn;
    %let bd = &max_combo_depth; %let bb = &beam_width; %let bn = &numeric_bins;

    %if not %length(&depth_list) %then %let depth_list = &max_combo_depth;
    %if not %length(&beam_list)  %then %let beam_list  = &beam_width;
    %if not %length(&bins_list)  %then %let bins_list  = &numeric_bins;
    %let na = %sysfunc(countw(&depth_list, %str( )));
    %let nb = %sysfunc(countw(&beam_list,  %str( )));
    %let nc = %sysfunc(countw(&bins_list,  %str( )));
    %let k = 0;
    %let best = -1E30;
    %let bestk = 0;

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

            %let sc = 0;
            %if %seg_nobs(sgr&k._segments) > 0 %then %do;
                proc sql noprint;
                    select sum(Business_Impact_Score) format=best32. into :sc trimmed from sgr&k._segments;
                quit;
            %end;
            %put NOTE: seg_autoslicer_grid - combo &k (depth=&da beam=&db bins=&dc) score=&sc;

            %if %sysevalf(&sc > &best) %then %do;
                %let best  = &sc;
                %let bestk = &k;
                %let bd = &da; %let bb = &db; %let bn = &dc;
            %end;
        %end;
      %end;
    %end;

    %do s = 1 %to 6;
        %let sfx = %scan(segments rules portfolio feature_psi pool log, &s, %str( ));
        data &out_prefix._&sfx; set sgr&bestk._&sfx; run;
    %end;

    data &out_prefix._selected_params;
        max_combo_depth = &bd; beam_width = &bb; numeric_bins = &bn;
        params_evaluated = &k; optimization_score = &best;
    run;

    proc datasets lib=work nolist nowarn; delete sgr: ; quit;

%mend seg_autoslicer_grid;
