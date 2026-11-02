/* ============================================================================
   seg_autoslicer.sas
   SAS port of techniques/autoslicer.py (AutoSlicerTechnique.run): adaptive
   beam search over conjunctions of single-feature predicates, scored by the
   shared engine.

   Algorithm (same order of operations as Python):
     1  seg_prep, derive gates; seg_as_predicates (quantile bins / categories)
     2  depth 1 = every atomic predicate  -> gate -> evaluate -> heuristic
     3  for depth 2..max_combo_depth:
          retain beam rows with h >= top_h*beam_retain_ratio; if fewer than
          min_beam_width take the first min_beam_width; cap at beam_width;
          expand each retained parent (in beam order) with every predicate of
          every feature it does not yet use (feature order, then bin order);
          skip duplicate conjunctions (first occurrence wins);
          gate -> evaluate -> heuristic; stop if no survivors or if
          (best_h_this_depth - best_h_so_far)/max(|best_so_far|,1e-6) <
          depth_improvement_tolerance (the level just evaluated is KEPT).
     4  seg_score_candidates over the whole pool, significance-first rank,
        Jaccard de-dup (pool 30), keep top_n.

   Outputs (WORK, prefix = &out_prefix):
     _segments   top-N, public column names (Dev_Count ... Root_Cause_Score)
     _rules      exact rule rows for the top-N (use these, not the label text)
     _portfolio  significant top-N re-ranked by Portfolio_Impact_Score
     _feature_psi in-segment per-feature PSI for the top-N
     _pool       every evaluated candidate with internal metric names (parity)
     _log        one row: thresholds, pool size, depth reached

   Defaults equal models/config.SlicerConfig. Not ported: Top_SHAP_Feature /
   Top_SHAP_PSI columns (diagnostic only).
   ============================================================================ */
%macro seg_autoslicer(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                      max_combo_depth=6, beam_width=30, min_beam_width=8, beam_retain_ratio=0.5,
                      depth_improvement_tolerance=0.05, numeric_bins=4, top_n=10,
                      min_events_per_slice=30, min_abs_count=, min_support=,
                      significance_alpha=0.05, max_segment_pct=0.35,
                      overlap_jaccard_threshold=0.70, rca_name_filter=Y, out_prefix=seg_as);

    %local nextid d go top_h cutoff nr best_so_far best_this rel stop depth_done nnew;

    proc datasets lib=work nolist nowarn;
        delete _sg_pool _sg_memmon_all _sg_rules_all _sg_fpsi_all;
    quit;

    %seg_prep(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
              weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
              min_abs_count=&min_abs_count, min_support=&min_support,
              min_events_per_slice=&min_events_per_slice, max_segment_pct=&max_segment_pct,
              rca_name_filter=&rca_name_filter);

    %seg_as_predicates(feature_cols=&feature_cols, numeric_bins=&numeric_bins);

    /* ---------------- depth 1: every atomic predicate ---------------- */
    %let nextid = 1;
    data _sg_cand;
        set _sg_pred;
        array c [&sg_nf] c1-c&sg_nf;
        do _i = 1 to &sg_nf; c[_i] = 0; end;
        c[feat_idx] = pred_id;
        cand_id = &nextid + _n_ - 1;
        depth   = 1;
        keep cand_id depth c1-c&sg_nf;
    run;
    %let nextid = %eval(&nextid + %seg_nobs(_sg_cand));

    %seg_as_step(cand=_sg_cand, shap_cols=&shap_cols);
    %let depth_done = 1;
    %let go = %sysevalf(&sg_step_n > 0);

    %if &go %then %do;
        data _sg_beam; set _sg_beam_new; run;
        proc sql noprint; select max(h) format=best32. into :best_so_far trimmed from _sg_beam; quit;
    %end;

    /* ---------------- depth 2..max: expand the beam ---------------- */
    %do d = 2 %to &max_combo_depth;
        %if &go %then %do;

            proc sql noprint; select max(h) format=best32. into :top_h trimmed from _sg_beam; quit;
            data _null_; call symputx('cutoff', put(&top_h * &beam_retain_ratio, best32.), 'L'); run;

            data _sg_ret; set _sg_beam; if h >= &cutoff; run;
            %let nr = %seg_nobs(_sg_ret);
            %if &nr < &min_beam_width %then %do;
                data _sg_ret; set _sg_beam(obs=&min_beam_width); run;
                %let nr = %seg_nobs(_sg_ret);
            %end;
            %if &nr > &beam_width %then %do;
                data _sg_ret; set _sg_ret(obs=&beam_width); run;
            %end;

            data _sg_exp(keep=seq key c1-c&sg_nf);
                set _sg_ret(keep=c1-c&sg_nf);
                array c [&sg_nf] c1-c&sg_nf;
                length key $200;
                do _p = 1 to &sg_npred;
                    set _sg_pred(keep=pred_id feat_idx) point=_p;
                    if c[feat_idx] = 0 then do;
                        c[feat_idx] = pred_id;
                        seq + 1;
                        key = catx('-', of c1-c&sg_nf);
                        output;
                        c[feat_idx] = 0;
                    end;
                end;
            run;
            proc sort data=_sg_exp nodupkey; by key; run;      /* keeps first occurrence */
            proc sort data=_sg_exp; by seq; run;

            data _sg_cand;
                set _sg_exp;
                cand_id = &nextid + _n_ - 1;
                depth   = &d;
                keep cand_id depth c1-c&sg_nf;
            run;
            %let nnew   = %seg_nobs(_sg_cand);
            %let nextid = %eval(&nextid + &nnew);

            %if &nnew = 0 %then %let go = 0;
            %else %do;
                %seg_as_step(cand=_sg_cand, shap_cols=&shap_cols);
                %let depth_done = &d;
                %if &sg_step_n = 0 %then %let go = 0;
                %else %do;
                    proc sql noprint; select max(h) format=best32. into :best_this trimmed from _sg_beam_new; quit;
                    data _null_;
                        rel = (&best_this - &best_so_far) / max(abs(&best_so_far), 1e-6);
                        call symputx('rel', put(rel, best32.), 'L');
                        call symputx('stop', rel < &depth_improvement_tolerance, 'L');
                        call symputx('best_so_far', put(max(&best_so_far, &best_this), best32.), 'L');
                    run;
                    %if &stop %then %let go = 0;
                    %else %do;
                        data _sg_beam; set _sg_beam_new; run;
                    %end;
                %end;
            %end;
        %end;
    %end;

    /* ---------------- final scoring, ranking, de-dup, publish ---------------- */
    %seg_publish(technique=AutoSlicer, out_prefix=&out_prefix, top_n=&top_n, dedup=Y,
                 overlap=&overlap_jaccard_threshold, pool_size=30, alpha=&significance_alpha,
                 dropvars=h depth c1-c&sg_nf);

    /* AutoSlicer-specific log columns */
    data &out_prefix._log;
        set &out_prefix._log;
        n_predicates  = &sg_npred;
        depth_reached = &depth_done;
    run;

%mend seg_autoslicer;
