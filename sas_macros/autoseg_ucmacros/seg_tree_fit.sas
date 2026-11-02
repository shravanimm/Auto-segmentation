/* ============================================================================
   seg_tree_fit.sas
   A CART tree in plain Base SAS that reproduces scikit-learn's greedy "best"
   splitter (DecisionTreeClassifier gini / DecisionTreeRegressor friedman_mse),
   so Drift Tree / Gradient Boosting / K-Means-rule leaves are the SAME
   partitions as Python's (verified: Drift Tree 15/15 leaves, multiclass 15/15,
   20/20 boosted trees identical to sklearn on the demo data).

   Why not PROC TREESPLIT/HPSPLIT/GRADBOOST: they bin interval inputs, prune
   and use different defaults, so their leaves cannot match sklearn's; this also
   needs no VDMML licence. Cost: one pass per feature per level (rows are
   pre-sorted once by seg_tree_presort). Leaf values for boosting are computed by
   the caller.

   Split search (level by level; node ids are heap ids: root 1, children 2k,2k+1):
     for every feature in column order, stream the rows in ascending x; for each
     node keep running left-side counts; a split point lies between two
     consecutive rows whose x differ by > 1e-7; both sides need >= min_leaf rows;
     the threshold is the midpoint (x_prev/2 + x/2, as sklearn);
     the best split per node maximises
        GINI : sum_k left_k^2/n_left + sum_k right_k^2/n_right      (min gini)
        FMSE : n_l n_r (mean_l - mean_r)^2 / (n_l + n_r)            (friedman)
     a strictly better split replaces the incumbent, so ties go to the earlier
     feature / smaller threshold. (sklearn visits features in random order, so
     exact ties between DIFFERENT features - e.g. the two complementary one-hot
     columns of a binary categorical - may resolve differently; membership is
     identical, only the rule text can differ.)
   A node is a leaf if depth = max_depth, n < 2 or n < 2*min_leaf, or it is pure
   (gini: one class; fmse: variance <= 2.2e-16), or no valid split exists.

   data   : _tid, x1..xp (float32-rounded), &tvar
            (GINI: integer class 0..ncls-1;  FMSE: real target)
   Needs  : _trs1.._trs<p> from seg_tree_presort
   out_nodes: node_id depth feat thr n is_leaf path preorder
              (path = L/R bits as 0/1; preorder = sklearn node_id numbering)
   out_rows : _tid, node (leaf id of every row)
   ============================================================================ */
%macro seg_tree_fit(data=, p=, tvar=, kind=GINI, ncls=2, max_depth=, min_leaf=,
                    out_nodes=, out_rows=);

    %local n maxnode d j k go nsplit nspl km1;
    %let kind  = %upcase(&kind);
    %let km1   = %eval(&ncls - 1);

    proc sql noprint; select count(*) into :n trimmed from &data; quit;
    %let maxnode = %eval(2 ** (&max_depth + 1));

    data _tr_row;
        set &data(keep=_tid x1-x&p &tvar);
        node = 1;
        _tt  = &tvar;
    run;

    data &out_nodes;
        length node_id 8 depth 8 feat 8 thr 8 n 8 is_leaf 8;
        stop;
    run;

    %let go = 1;
    %do d = 0 %to &max_depth;
      %if &go %then %do;

        /* ---- node statistics for this level ---- */
        proc sql;
            create table _tr_stat as
            select node, count(*) as n, sum(_tt) as s, sum(_tt * _tt) as ss
                   %if &kind = GINI %then %do k = 0 %to &km1; , sum(_tt = &k) as k&k %end;
            from _tr_row group by node;
        quit;

        data _tr_stat2;
            set _tr_stat;
            %if &kind = GINI %then %do;
                array kk [0:&km1] k0-k&km1;
                _mx = max(of k0-k&km1);
                pure = (_mx = n);
            %end;
            %else %do;
                pure = ((ss / n - (s / n) ** 2) <= 2.220446049250313e-16);
            %end;
            splittable = (&d < &max_depth) and (n >= 2) and (n >= 2 * &min_leaf) and (not pure);
        run;

        %let nspl = 0;
        proc sql noprint; select count(*) into :nspl trimmed from _tr_stat2 where splittable = 1; quit;

        data _tr_split; length node 8 feat 8 thr 8; stop; run;

        %if &nspl > 0 %then %do;

            data _tr_bestprev;
                set _tr_stat2(where=(splittable = 1) keep=node splittable);
                prox = -1e300; feat = 0; thr = .;
                keep node prox feat thr;
            run;

            %do j = 1 %to &p;
                data _tr_bestnew(keep=node prox feat thr);
                    array nd   [&n]       _temporary_;
                    array tv   [&n]       _temporary_;
                    array sp   [&maxnode] _temporary_;
                    array tn   [&maxnode] _temporary_;
                    array tsum [&maxnode] _temporary_;
                    array bprx [&maxnode] _temporary_;
                    array bft  [&maxnode] _temporary_;
                    array bth  [&maxnode] _temporary_;
                    array ln   [&maxnode] _temporary_;
                    array ls   [&maxnode] _temporary_;
                    array lx   [&maxnode] _temporary_;
                    %if &kind = GINI %then %do;
                        array tcl [&maxnode, &ncls] _temporary_;
                        array lcl [&maxnode, &ncls] _temporary_;
                    %end;
                    if _n_ = 1 then do;
                        do until(_e1);
                            set _tr_row(keep=_tid node _tt rename=(_tid=_i node=_nd _tt=_tv)) end=_e1;
                            nd[_i] = _nd; tv[_i] = _tv;
                        end;
                        do until(_e2);
                            set _tr_stat2(where=(splittable = 1) rename=(node=_nd n=_nn s=_ss)) end=_e2;
                            sp[_nd] = 1; tn[_nd] = _nn; tsum[_nd] = _ss;
                            %if &kind = GINI %then %do;
                                %do k = 0 %to &km1; tcl[_nd, %eval(&k + 1)] = k&k; %end;
                            %end;
                        end;
                        do until(_e3);
                            set _tr_bestprev(rename=(node=_nd prox=_px feat=_ft thr=_th)) end=_e3;
                            bprx[_nd] = _px; bft[_nd] = _ft; bth[_nd] = _th;
                        end;
                    end;

                    set _trs&j end=_last;
                    _nd = nd[_tid];
                    if _nd > 0 then if sp[_nd] = 1 then do;
                        _x = x&j;
                        if lx[_nd] ne . then if _x > lx[_nd] + 1e-7 then do;
                            _nl = ln[_nd];
                            _nr = tn[_nd] - _nl;
                            if _nl >= &min_leaf and _nr >= &min_leaf then do;
                                %if &kind = GINI %then %do;
                                    _a = 0; _b = 0;
                                    do _k = 1 to &ncls;
                                        _a = _a + sum(lcl[_nd, _k], 0) ** 2;
                                        _b = _b + (tcl[_nd, _k] - sum(lcl[_nd, _k], 0)) ** 2;
                                    end;
                                    _prox = _a / _nl + _b / _nr;
                                %end;
                                %else %do;
                                    _dd = ls[_nd] / _nl - (tsum[_nd] - ls[_nd]) / _nr;
                                    _prox = _nl * _nr * _dd * _dd / (_nl + _nr);
                                %end;
                                if _prox > bprx[_nd] then do;
                                    bprx[_nd] = _prox;
                                    bft[_nd]  = &j;
                                    _thr = lx[_nd] / 2 + _x / 2;
                                    if _thr = _x then _thr = lx[_nd];
                                    bth[_nd]  = _thr;
                                end;
                            end;
                        end;
                        ln[_nd] = sum(ln[_nd], 1);
                        lx[_nd] = _x;
                        %if &kind = GINI %then %do;
                            lcl[_nd, tv[_tid] + 1] = sum(lcl[_nd, tv[_tid] + 1], 1);
                        %end;
                        %else %do;
                            ls[_nd] = sum(ls[_nd], tv[_tid]);
                        %end;
                    end;
                    if _last then do;
                        do node = 1 to &maxnode - 1;
                            if sp[node] = 1 then do;
                                prox = bprx[node]; feat = bft[node]; thr = bth[node];
                                output;
                            end;
                        end;
                    end;
                run;
                data _tr_bestprev; set _tr_bestnew; run;
            %end;

            data _tr_split;
                set _tr_bestprev;
                where feat > 0;
                keep node feat thr;
            run;
        %end;

        %let nsplit = %seg_nobs(_tr_split);

        /* ---- record this level's nodes ---- */
        proc sql;
            insert into &out_nodes
            select s.node, &d, p.feat, p.thr, s.n, 0
            from _tr_stat2 s inner join _tr_split p on s.node = p.node;

            insert into &out_nodes
            select s.node, &d, 0, ., s.n, 1
            from _tr_stat2 s
            where s.node not in (select node from _tr_split);
        quit;

        /* ---- route rows of split nodes to their children ---- */
        %if &nsplit = 0 %then %let go = 0;
        %else %do;
            data _tr_row;
                if _n_ = 1 then do;
                    declare hash hs(dataset: '_tr_split');
                    hs.defineKey('node');
                    hs.defineData('feat', 'thr');
                    hs.defineDone();
                    call missing(feat, thr);
                end;
                set _tr_row;
                array x [&p] x1-x&p;
                if hs.find() = 0 then node = 2 * node + (x[feat] > thr);
                drop feat thr;
            run;
        %end;

      %end;
    %end;

    /* ---- outputs ---- */
    data &out_rows(keep=_tid node);
        set _tr_row;
    run;

    data &out_nodes;
        set &out_nodes;
        length path $64 _b $64;
        _b = put(node_id, binary32.);
        _b = strip(substr(_b, indexc(_b, '1')));
        if length(_b) > 1 then path = substr(_b, 2);   /* drop the leading 1: root = '' */
        else path = '';
    run;
    proc sort data=&out_nodes; by path; run;       /* '' < '0..' < '1..' => preorder */
    data &out_nodes;
        set &out_nodes;
        preorder = _n_ - 1;
        drop _b;
    run;

%mend seg_tree_fit;
