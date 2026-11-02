/* ============================================================================
   seg_drift_tree.sas
   SAS port of techniques/drift_tree.py (Drift Localization Tree).

   A classification tree is trained to tell DEVELOPMENT rows (0) from
   MONITORING rows (1) on the combined data; each leaf is a candidate segment.
     tree : gini, max_depth, min_samples_leaf (fraction => ceil(frac * N), the
            same integer sklearn derives), no class weights
     rules: canonicalised path conditions, equality parts first
     leaves are evaluated in depth-first order; contradictory paths are dropped
     NO de-duplication (leaves are disjoint), top_n by significance-first rank
   The split search is seg_tree_fit (verified identical to sklearn's partition).
   Output tables (prefix &out_prefix): _segments _rules _portfolio _feature_psi
   _pool _log. Segment extra column: Leaf_ID (sklearn preorder node id).
   Defaults equal models/config.DLTConfig.
   ============================================================================ */
%macro seg_drift_tree(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=,
                      numeric_cols=, categorical_cols=, shap_cols=,
                      max_depth=3, min_samples_leaf=0.05, top_n=10,
                      min_events_per_slice=30, min_abs_count=, min_support=,
                      significance_alpha=0.05, max_segment_pct=0.35, rca_name_filter=Y,
                      out_prefix=seg_dt);

    %local nn nc p minleaf;

    %seg_prep(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
              weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
              min_abs_count=&min_abs_count, min_support=&min_support,
              min_events_per_slice=&min_events_per_slice, max_segment_pct=&max_segment_pct,
              rca_name_filter=&rca_name_filter);
    %let sg_premem = Y;

    %let nn = %sysfunc(countw(&numeric_cols, %str( )));
    %let nc = %sysfunc(countw(&categorical_cols, %str( )));

    %seg_tree_matrix(numeric_cols=&numeric_cols, categorical_cols=&categorical_cols,
                     out=_tr_x, map=_tr_map);
    %let p = &sg_tr_p;

    /* min_samples_leaf as a fraction => ceil(frac*N) computed WITHOUT SAS's fuzzy CEIL */
    data _null_;
        x = &min_samples_leaf * (&sg_ndev + &sg_nmon);
        call symputx('minleaf', int(x) + (x > int(x)), 'L');
    run;
    %put NOTE: seg_drift_tree - rows=%eval(&sg_ndev + &sg_nmon) min_samples_leaf=&minleaf features=&p;

    %seg_tree_presort(data=_tr_x, p=&p);
    %seg_tree_fit(data=_tr_x, p=&p, tvar=y, kind=GINI, ncls=2, max_depth=&max_depth,
                  min_leaf=&minleaf, out_nodes=_dt_nodes0, out_rows=_dt_rows);

    data _dt_nodes; set _dt_nodes0; gid = 0; run;
    %seg_tree_rules(nodes=_dt_nodes, map=_tr_map, nsrc=%eval(&nn + &nc), mode=SIMPLIFY,
                    root_label=All Customers (Root), out_defs=_dt_defs, out_rules=_dt_rules);

    /* candidates: usable leaves, depth-first order */
    proc sql;
        create table _dt_c0 as
        select n.node_id as leaf, n.preorder as Leaf_ID, d.Segment_Definition
        from _dt_nodes n inner join _dt_defs d on n.node_id = d.leaf
        where n.is_leaf = 1 and d.ok = 1
        order by n.path;
    quit;
    data _dt_cand; set _dt_c0; cand_id = _n_; run;

    proc sql;
        create table _sg_memb_dev as
        select c.cand_id, r._tid as _rid from _dt_rows r, _dt_cand c
        where r.node = c.leaf and r._tid <= &sg_ndev;
        create table _sg_memb_mon as
        select c.cand_id, r._tid - &sg_ndev as _rid from _dt_rows r, _dt_cand c
        where r.node = c.leaf and r._tid > &sg_ndev;
        create table _dt_rl as
        select c.cand_id, r.feature, r.feat_idx, r.ptype, r.lower, r.upper, r.lo_inf, r.hi_inf,
               r.value, r.label
        from _dt_cand c inner join _dt_rules r on c.leaf = r.leaf;
    quit;

    %seg_eval_pool(cand=_dt_cand, defs=_dt_cand, rules=_dt_rl, shap_cols=&shap_cols);
    %seg_publish(technique=Drift Localization Tree, out_prefix=&out_prefix, top_n=&top_n,
                 dedup=N, alpha=&significance_alpha, dropvars=leaf);

    data &out_prefix._log; set &out_prefix._log; tree_leaves = %seg_nobs(_dt_c0); run;
    %let sg_premem = N;

%mend seg_drift_tree;
