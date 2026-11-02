/* ============================================================================
   seg_gradient_boosting.sas
   SAS port of techniques/gradient_boosting.py.

   Gradient boosting (log-loss) is trained to tell DEV rows (0) from MONITORING
   rows (1); the leaves of EVERY tree are candidate segments.
     init      : log-odds of the monitoring share
     each tree : regression tree (friedman_mse, max_depth, min_samples_leaf as
                 ceil(frac*N)) on the residuals y - sigmoid(F) - seg_tree_fit
                 FMSE; leaf value = sum(residual)/sum(p(1-p)) (Newton step);
                 F += learning_rate * value
     leaves are scanned tree by tree, depth-first; a rule already seen in an
     earlier tree is skipped; then gates -> shared evaluation -> scoring ->
     significance-first rank -> Jaccard de-dup (pool 30) -> top_n
   Because tree t depends only on trees < t, only the first max_trees_scanned
   trees are fitted when that option is set (same result as Python, which fits
   all but scans the first M).
   Feature order for the matrix and root-cause PSI is numeric_cols then
   categorical_cols (as Python builds feature_cols for this technique).
   Extra segment columns: Tree_Idx, Leaf_ID. Defaults = models/config.GBConfig.
   ============================================================================ */
%macro seg_gradient_boosting(dev=, mon=, target_col=, score_col=, weight_col=,
                      numeric_cols=, categorical_cols=, shap_cols=,
                      n_estimators=100, max_depth=3, learning_rate=0.1, min_samples_leaf=0.05,
                      max_trees_scanned=, top_n=10,
                      min_events_per_slice=30, min_abs_count=, min_support=,
                      significance_alpha=0.05, max_segment_pct=0.35,
                      overlap_jaccard_threshold=0.70, rca_name_filter=Y, out_prefix=seg_gb);

    %local nn nc p minleaf ntree t fcols;

    %let fcols = &numeric_cols &categorical_cols;
    %seg_prep(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
              weight_col=&weight_col, feature_cols=&fcols, shap_cols=&shap_cols,
              min_abs_count=&min_abs_count, min_support=&min_support,
              min_events_per_slice=&min_events_per_slice, max_segment_pct=&max_segment_pct,
              rca_name_filter=&rca_name_filter);
    %let sg_premem = Y;

    %let nn = %sysfunc(countw(&numeric_cols, %str( )));
    %let nc = %sysfunc(countw(&categorical_cols, %str( )));

    %seg_tree_matrix(numeric_cols=&numeric_cols, categorical_cols=&categorical_cols,
                     out=_tr_x, map=_tr_map);
    %let p = &sg_tr_p;

    data _null_;
        x = &min_samples_leaf * (&sg_ndev + &sg_nmon);
        call symputx('minleaf', int(x) + (x > int(x)), 'L');
    run;
    %let ntree = &n_estimators;
    %if %length(&max_trees_scanned) %then %do;
        %if &max_trees_scanned > 0 and &max_trees_scanned < &ntree %then %let ntree = &max_trees_scanned;
    %end;
    %put NOTE: seg_gradient_boosting - trees=&ntree depth=&max_depth min_samples_leaf=&minleaf features=&p;

    %seg_tree_presort(data=_tr_x, p=&p);

    /* ---- boosting loop ---- */
    proc datasets lib=work nolist nowarn; delete _gb_nodes _gb_lr; quit;

    data _gb_work;
        set _tr_x;
        retain _f0;
        if _n_ = 1 then do;
            do until(_e); set _tr_x(keep=y rename=(y=_yy)) end=_e; _s1 + _yy; _cnt + 1; end;
            _pri = _s1 / _cnt;
            _f0 = log(_pri / (1 - _pri));
        end;
        F = _f0;
        drop _f0 _yy _s1 _cnt _pri _e;
    run;

    %do t = 0 %to %eval(&ntree - 1);
        data _gb_work;
            set _gb_work;
            _p = 1 / (1 + exp(-F));
            res = y - _p;
        run;

        %seg_tree_fit(data=_gb_work, p=&p, tvar=res, kind=FMSE, ncls=1, max_depth=&max_depth,
                      min_leaf=&minleaf, out_nodes=_gb_n1, out_rows=_gb_r1);

        /* Newton leaf values and prediction update */
        proc sql;
            create table _gb_val as
            select r.node, sum(w.res) as num, sum(w._p * (1 - w._p)) as den
            from _gb_r1 r inner join _gb_work w on r._tid = w._tid
            group by r.node;
        quit;
        data _gb_work;
            if _n_ = 1 then do;
                declare hash hv(dataset: '_gb_val');
                hv.defineKey('node');
                hv.defineData('num', 'den');
                hv.defineDone();
                call missing(num, den);
            end;
            merge _gb_work _gb_r1(keep=_tid node);
            by _tid;
            if hv.find() = 0 then F = F + &learning_rate * ifn(abs(den) < 1e-150, 0, num / den);
            drop node num den _p res;
        run;

        data _gb_n1; set _gb_n1; gid = &t; run;
        data _gb_r1; set _gb_r1; gid = &t; run;
        proc append base=_gb_nodes data=_gb_n1 force; run;
        proc append base=_gb_lr    data=_gb_r1 force; run;
    %end;

    /* ---- rules, first-seen de-duplication across trees, membership ---- */
    %seg_tree_rules(nodes=_gb_nodes, map=_tr_map, nsrc=%eval(&nn + &nc), mode=SIMPLIFY,
                    root_label=All Customers (Root), out_defs=_gb_defs, out_rules=_gb_rules);

    proc sql;
        create table _gb_c0 as
        select n.gid as Tree_Idx, n.node_id as leaf, n.preorder as Leaf_ID, d.Segment_Definition
        from _gb_nodes n inner join _gb_defs d on n.gid = d.gid and n.node_id = d.leaf
        where n.is_leaf = 1 and d.ok = 1
        order by n.gid, n.path;
    quit;

    data _gb_cand;
        if _n_ = 1 then do;
            declare hash seen();
            seen.defineKey('Segment_Definition');
            seen.defineDone();
        end;
        set _gb_c0;
        if seen.check() = 0 then delete;
        rc = seen.add();
        cand_id + 1;
        drop rc;
    run;

    proc sql;
        create table _sg_memb_dev as
        select c.cand_id, r._tid as _rid from _gb_lr r, _gb_cand c
        where r.gid = c.Tree_Idx and r.node = c.leaf and r._tid <= &sg_ndev;
        create table _sg_memb_mon as
        select c.cand_id, r._tid - &sg_ndev as _rid from _gb_lr r, _gb_cand c
        where r.gid = c.Tree_Idx and r.node = c.leaf and r._tid > &sg_ndev;
        create table _gb_rl as
        select c.cand_id, r.feature, r.feat_idx, r.ptype, r.lower, r.upper, r.lo_inf, r.hi_inf,
               r.value, r.label
        from _gb_cand c inner join _gb_rules r on c.Tree_Idx = r.gid and c.leaf = r.leaf;
    quit;

    %seg_eval_pool(cand=_gb_cand, defs=_gb_cand, rules=_gb_rl, shap_cols=&shap_cols);
    %seg_publish(technique=Gradient Boosting, out_prefix=&out_prefix, top_n=&top_n, dedup=Y,
                 overlap=&overlap_jaccard_threshold, pool_size=30, alpha=&significance_alpha,
                 dropvars=leaf);

    data &out_prefix._log; set &out_prefix._log; trees_fitted = &ntree; run;
    %let sg_premem = N;

%mend seg_gradient_boosting;
