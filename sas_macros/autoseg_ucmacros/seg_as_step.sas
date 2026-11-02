/* ============================================================================
   seg_as_step.sas
   One beam-search level of AutoSlicer: gate -> evaluate -> heuristic.
   Takes a candidate table (cand_id, depth, c1..cN), keeps the survivors of the
   support/event gates, evaluates them fully (seg_evaluate_candidates) and
   appends to the accumulating tables:
       _sg_pool        evaluated candidates (+ Segment_Definition, h, depth, c*)
       _sg_memmon_all  cand_id,_rid  monitoring-row membership (for dedup)
       _sg_rules_all   exact rule rows
       _sg_fpsi_all    per-feature in-segment PSI
   Leaves the new beam (survivors sorted by heuristic desc, then cand_id asc =
   Python's stable sort) in _sg_beam_new and the survivor count in sg_step_n.

   heuristic_score (techniques/autoslicer.py) - beam prioritisation ONLY:
     psi*.30 + mon_weight_pct*.25 + max(0,-d_gini)*.20 + max(0,-d_ks)*.15 + |d_br|*.10
   ============================================================================ */
%macro seg_as_step(cand=, shap_cols=);

    %global sg_step_n;

    %seg_candidate_filter(cand=&cand, out=_sg_surv);
    %let sg_step_n = %seg_nobs(_sg_surv);

    %if &sg_step_n = 0 %then %do;
        data _sg_beam_new; length cand_id 8 h 8; stop; run;
    %end;
    %else %do;
        %seg_evaluate_candidates(cand=_sg_surv, out=_sg_ev, shap_cols=&shap_cols);
        %seg_cand_rules(cand=_sg_surv, out_rules=_sg_rl, out_defs=_sg_df);

        data _sg_evx;
            merge _sg_ev _sg_df _sg_surv(keep=cand_id depth c1-c&sg_nf);
            by cand_id;
            h = psi * 0.30
              + mon_weight_pct * 0.25
              + max(0, -delta_gini) * 0.20
              + max(0, -delta_ks) * 0.15
              + abs(delta_br) * 0.10;
        run;

        proc append base=_sg_pool data=_sg_evx force; run;
        proc append base=_sg_rules_all data=_sg_rl force; run;
        proc append base=_sg_fpsi_all data=_sg_fpsi force; run;

        data _sg_mm(keep=cand_id _rid);
            set _sg_mem_mon;
        run;
        proc append base=_sg_memmon_all data=_sg_mm force; run;

        proc sort data=_sg_evx(keep=cand_id h depth c1-c&sg_nf) out=_sg_beam_new;
            by descending h cand_id;
        run;
    %end;

%mend seg_as_step;
