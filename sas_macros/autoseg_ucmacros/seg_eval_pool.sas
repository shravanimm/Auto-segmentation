/* ============================================================================
   seg_eval_pool.sas
   Evaluation step for techniques whose candidates are known up front (tree
   leaves, clusters, boosted-tree leaves): gate -> evaluate -> append to the
   accumulating tables read by seg_publish. Needs sg_premem = Y and the
   membership tables _sg_memb_dev / _sg_memb_mon.

   cand  : table with cand_id (all candidates, in Python evaluation order)
   defs  : cand_id, Segment_Definition [, extra technique columns, e.g. Leaf_ID]
   rules : cand_id, feature, feat_idx, ptype, lower, upper, lo_inf, hi_inf, value, label
   Appends to: _sg_pool _sg_memmon_all _sg_rules_all _sg_fpsi_all
   ============================================================================ */
%macro seg_eval_pool(cand=, defs=, rules=, shap_cols=);

    proc datasets lib=work nolist nowarn;
        delete _sg_pool _sg_memmon_all _sg_rules_all _sg_fpsi_all;
    quit;

    %seg_candidate_filter(cand=&cand, out=_sg_surv);

    %if %seg_nobs(_sg_surv) = 0 %then %do;
        %put NOTE: seg_eval_pool - no candidate passed the support/event gates.;
    %end;
    %else %do;
        %seg_evaluate_candidates(cand=_sg_surv, out=_sg_ev, shap_cols=&shap_cols);

        proc sort data=&defs out=_sg_defs_s; by cand_id; run;
        data _sg_pool;
            merge _sg_ev(in=_a) _sg_defs_s;
            by cand_id;
            if _a;
        run;

        proc sql;
            create table _sg_rules_all as
            select * from &rules where cand_id in (select cand_id from _sg_surv);
        quit;

        data _sg_fpsi_all; set _sg_fpsi; run;
        data _sg_memmon_all(keep=cand_id _rid); set _sg_mem_mon; run;
    %end;

%mend seg_eval_pool;
