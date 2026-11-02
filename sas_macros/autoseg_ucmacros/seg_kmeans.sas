/* ============================================================================
   seg_kmeans.sas
   SAS port of techniques/kmeans.py (K-Means Clustering).

   1  encode (dev-fit scaler / one-hot)            seg_km_encode
   2  choose k (validity + stability + drift)       seg_km_select_k
   3  dev clusters = fit with the configured seed; monitoring rows -> nearest
      DEV centre
   4  explain: a shallow multiclass tree (gini, max_tree_depth, min_samples_leaf =
      max(20, int(1% of dev))) is trained on the raw dev features to predict the
      cluster; each cluster's rule is the path to the leaf holding most of its
      rows (PLAIN canonical order). Rule_Precision / Rule_Recall report how well
      that rule describes the cluster. IMPORTANT: real membership is the nearest
      centre - the rule is only a description (as in Python). The centres and the
      encoding statistics are published (&out_prefix._centroids / _encoding) so
      consumers can apply the segmentation exactly.
   5  each cluster is a candidate: gates -> shared evaluation -> scoring ->
      significance-first rank (NO de-dup) -> top_n
   NOT reproducible bit-for-bit: k-means randomness (see seg_km_fit) - compare
   with the Python run statistically (similar k, similar top segments).
   Defaults equal models/config.KMeansConfig. Extra segment columns: Cluster_ID,
   Rule_Precision, Rule_Recall.
   ============================================================================ */
%macro seg_kmeans(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=,
                  numeric_cols=, categorical_cols=, shap_cols=,
                  k_min=2, k_max=12, min_cluster_pct=0.03, seed=42, max_tree_depth=4,
                  drift_aware=Y, drift_weight=0.4, n_init=10, top_n=10,
                  min_events_per_slice=30, min_abs_count=, min_support=,
                  significance_alpha=0.05, max_segment_pct=0.35, rca_name_filter=Y,
                  out_prefix=seg_km);

    %local nn nc d k n nmon minleaf p;

    %seg_prep(dev=&dev, mon=&mon, target_col=&target_col, score_col=&score_col,
              weight_col=&weight_col, feature_cols=&feature_cols, shap_cols=&shap_cols,
              min_abs_count=&min_abs_count, min_support=&min_support,
              min_events_per_slice=&min_events_per_slice, max_segment_pct=&max_segment_pct,
              rca_name_filter=&rca_name_filter);
    %let sg_premem = Y;
    %let n    = &sg_ndev;
    %let nmon = &sg_nmon;
    %let nn   = %sysfunc(countw(&numeric_cols, %str( )));
    %let nc   = %sysfunc(countw(&categorical_cols, %str( )));

    %seg_km_encode(numeric_cols=&numeric_cols, categorical_cols=&categorical_cols);
    %let d = &sg_km_d;

    %seg_km_select_k(k_min=&k_min, k_max=&k_max, min_cluster_pct=&min_cluster_pct, seed=&seed,
                     drift_aware=&drift_aware, drift_weight=&drift_weight, n_init=&n_init,
                     d=&d, n=&n, nmon=&nmon);
    %if not %length(&sg_km_bestk) %then %do;
        %let sg_premem = N;
        %return;
    %end;
    %let k = &sg_km_bestk;

    /* ---- final assignment ---- */
    %seg_km_predict(data=_km_xm, cen=_km_ca&k, d=&d, k=&k, out=_km_lm);
    data _km_ld; set _km_la&k; run;

    /* ---- rule distillation on raw dev features ---- */
    %seg_tree_matrix(numeric_cols=&numeric_cols, categorical_cols=&categorical_cols,
                     out=_tr_x, map=_tr_map, scope=DEV, miss=__MISSING__);
    %let p = &sg_tr_p;
    data _km_tx;
        merge _tr_x _km_ld(rename=(_rid=_tid));
        by _tid;
    run;
    data _null_;
        m = int(0.01 * &n);
        call symputx('minleaf', max(20, m), 'L');
    run;
    %seg_tree_presort(data=_km_tx, p=&p);
    %seg_tree_fit(data=_km_tx, p=&p, tvar=lab, kind=GINI, ncls=&k, max_depth=&max_tree_depth,
                  min_leaf=&minleaf, out_nodes=_km_n0, out_rows=_km_rows);
    data _km_nodes; set _km_n0; gid = 0; run;
    %seg_tree_rules(nodes=_km_nodes, map=_tr_map, nsrc=%eval(&nn + &nc), mode=PLAIN,
                    root_label=, out_defs=_km_defs, out_rules=_km_rules);

    /* leaf holding most of each cluster (ties: depth-first first) */
    proc sql;
        create table _km_lc as
        select l.lab, r.node, count(*) as cnt
        from _km_rows r inner join _km_ld l on r._tid = l._rid
        group by l.lab, r.node;
        create table _km_ln as select node, count(*) as lsize from _km_rows group by node;
        create table _km_cs as select lab, count(*) as csize from _km_ld group by lab;
        create table _km_bl0 as
        select c.lab, c.node as leaf, c.cnt, n.lsize, s.csize, p.path
        from _km_lc c, _km_ln n, _km_cs s, _km_nodes p
        where c.node = n.node and c.lab = s.lab and c.node = p.node_id
        order by c.lab, c.cnt desc, p.path;
    quit;
    data _km_bl;
        set _km_bl0;
        by lab;
        if first.lab;
        Rule_Precision = cnt / lsize;
        Rule_Recall    = cnt / csize;
    run;

    proc sql;
        create table _km_cand as
        select b.lab + 1 as cand_id, b.lab as Cluster_ID,
               ('Cluster_' || strip(put(b.lab, best12.)) || ': ' ||
                    case when d.ok = 1 and d.Segment_Definition ne '' then strip(d.Segment_Definition)
                         else ('Cluster_' || strip(put(b.lab, best12.)) || ' (centroid)') end)
                    as Segment_Definition length=1000,
               b.Rule_Precision, b.Rule_Recall, b.leaf
        from _km_bl b left join _km_defs d on b.leaf = d.leaf
        order by b.lab;

        create table _km_rl as
        select c.cand_id, r.feature, r.feat_idx, r.ptype, r.lower, r.upper, r.lo_inf, r.hi_inf,
               r.value, r.label
        from _km_cand c inner join _km_rules r on c.leaf = r.leaf;

        create table _sg_memb_dev as select lab + 1 as cand_id, _rid from _km_ld;
        create table _sg_memb_mon as select lab + 1 as cand_id, _rid from _km_lm;
    quit;

    %seg_eval_pool(cand=_km_cand, defs=_km_cand, rules=_km_rl, shap_cols=&shap_cols);
    %seg_publish(technique=K-Means Clustering, out_prefix=&out_prefix, top_n=&top_n, dedup=N,
                 alpha=&significance_alpha, dropvars=leaf);

    /* ---- extras: diagnostics + what a consumer needs to apply the clusters ---- */
    data &out_prefix._k_diagnostics; set _km_diag; run;
    data &out_prefix._centroids;     set _km_ca&k; run;
    data &out_prefix._encoding;      set _km_map; run;
    data &out_prefix._log; set &out_prefix._log; optimal_k = &k; run;
    %let sg_premem = N;

%mend seg_kmeans;
