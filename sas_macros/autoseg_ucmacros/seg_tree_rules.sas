/* ============================================================================
   seg_tree_rules.sas
   Turns the leaves of one or more fitted trees into human-readable rules and
   exact rule rows - the SAS port of utils/preprocessing.extract_tree_rules +
   canonicalize_path_conditions + simplify_rule_list.

   For each leaf (gid = tree id, 0 for single trees; leaf = heap node id):
     * walk root -> leaf collecting (feature, threshold, <= | >) conditions
       ('<=' goes left, '>' goes right; a one-hot column splits at 0.5)
     * canonicalise per SOURCE feature, in order of first appearance:
         numeric : lower = max of '>' thresholds, upper = min of '<=' thresholds
                   -> "f >= lower" then "f < upper";  lower >= upper => the
                   path is contradictory and the leaf is dropped (ok = 0)
         category: a positive "= v" wins over any "!= x"; otherwise the "!= x"
                   list sorted alphabetically
       categorical parts are listed before numeric parts
     * mode SIMPLIFY (Drift Tree, Gradient Boosting): equality parts first
       (simplify_rule_list); mode PLAIN (K-Means rules): canonical order
     * a leaf with no conditions gets &root_label

   nodes : gid, node_id, feat, thr, is_leaf ... (seg_tree_fit out_nodes + gid)
   map   : seg_tree_matrix map (fidx, kind, src_idx, srcname, val)
   Outputs
     &out_defs  : gid, leaf, ok, Segment_Definition
     &out_rules : gid, leaf, feature, feat_idx, ptype (N | C | X for "!="),
                  lower, upper, lo_inf, hi_inf, value, label     (EXACT thresholds)
   Display thresholds are rounded to 2 dp (seg_fmtnum); the rule rows carry the
   full-precision values - rounded text is NOT a faithful definition.
   ============================================================================ */
%macro seg_tree_rules(nodes=, map=, nsrc=, mode=SIMPLIFY, root_label=All Customers (Root),
                      out_defs=, out_rules=);

    /* ---- 1. conditions along every root->leaf path ---- */
    data _tr_cond(keep=gid leaf seq feat thr dir);
        length dir $2;
        if _n_ = 1 then do;
            declare hash hn(dataset: "&nodes(where=(is_leaf = 0) keep=gid node_id feat thr depth is_leaf)");
            hn.defineKey('gid', 'node_id');
            hn.defineData('feat', 'thr', 'depth');
            hn.defineDone();
        end;
        set &nodes(where=(is_leaf = 1) keep=gid node_id is_leaf rename=(node_id=leaf));
        call missing(feat, thr, depth);
        cur = leaf;
        do while(cur > 1);
            par = floor(cur / 2);
            node_id = par;
            if hn.find() = 0 then do;
                seq = depth;
                dir = ifc(mod(cur, 2) = 0, '<=', '>');
                output;
            end;
            cur = par;
        end;
    run;
    proc sort data=_tr_cond; by gid leaf seq; run;

    /* ---- 2. canonicalise ---- */
    data &out_defs(keep=gid leaf ok Segment_Definition)
         &out_rules(keep=gid leaf feature feat_idx ptype lower upper lo_inf hi_inf value label);
        array mkind [&sg_tr_p] $1   _temporary_;
        array msrc  [&sg_tr_p]      _temporary_;
        array mval  [&sg_tr_p] $200 _temporary_;
        array skind [&nsrc] $1  _temporary_;
        array sname [&nsrc] $64 _temporary_;
        array lo    [&nsrc]     _temporary_;
        array up    [&nsrc]     _temporary_;
        array fseq  [&nsrc]     _temporary_;
        array posv  [&nsrc] $200  _temporary_;
        array negs  [&nsrc] $2000 _temporary_;
        array ng    [60] $200 _ng1-_ng60;
        length feature $64 ptype $1 value $200 label $400 Segment_Definition $1000
               cat_text eq_text neg_text num_text $1000 part part2 $400 _v1 _v2 $40;

        if _n_ = 1 then do;
            do until(_e);
                set &map(keep=fidx kind src_idx srcname val) end=_e;
                mkind[fidx] = kind; msrc[fidx] = src_idx; mval[fidx] = val;
                skind[src_idx] = kind; sname[src_idx] = srcname;
            end;
        end;

        set _tr_cond;
        by gid leaf;

        if first.leaf then do;
            do _s = 1 to &nsrc; lo[_s] = .; up[_s] = .; fseq[_s] = .; posv[_s] = ''; negs[_s] = ''; end;
            fcount = 0;
        end;

        _s = msrc[feat];
        if fseq[_s] = . then do; fcount + 1; fseq[_s] = fcount; end;
        if mkind[feat] = 'N' then do;
            if dir = '<=' then up[_s] = min(up[_s], thr);
            else lo[_s] = max(lo[_s], thr);
        end;
        else do;
            if dir = '<=' then negs[_s] = catx('|', negs[_s], mval[feat]);
            else posv[_s] = mval[feat];
        end;

        if last.leaf then do;
            ok = 1;
            cat_text = ''; eq_text = ''; neg_text = ''; num_text = '';

            /* categorical sources, first-appearance order */
            do _f = 1 to fcount;
                do _s = 1 to &nsrc;
                    if fseq[_s] = _f and skind[_s] = 'C' then do;
                        feature = sname[_s]; feat_idx = _s; lower = .; upper = .; lo_inf = 0; hi_inf = 0;
                        if posv[_s] ne '' then do;
                            part = catx(' ', sname[_s], '=', posv[_s]);
                            cat_text = catx(' AND ', cat_text, part);
                            eq_text  = catx(' AND ', eq_text, part);
                            ptype = 'C'; value = posv[_s]; label = part; output &out_rules;
                        end;
                        else do;
                            _nn = countw(negs[_s], '|');
                            do _q = 1 to 60; ng[_q] = repeat('~', 4); end;
                            do _q = 1 to _nn; ng[_q] = scan(negs[_s], _q, '|'); end;
                            call sortc(of ng[*]);
                            do _q = 1 to _nn;
                                part = catx(' ', sname[_s], '!=', ng[_q]);
                                cat_text = catx(' AND ', cat_text, part);
                                neg_text = catx(' AND ', neg_text, part);
                                ptype = 'X'; value = ng[_q]; label = part; output &out_rules;
                            end;
                        end;
                    end;
                end;
            end;

            /* numeric sources, first-appearance order */
            do _f = 1 to fcount;
                do _s = 1 to &nsrc;
                    if fseq[_s] = _f and skind[_s] = 'N' then do;
                        if lo[_s] ne . and up[_s] ne . then if lo[_s] >= up[_s] then ok = 0;
                        feature = sname[_s]; feat_idx = _s; ptype = 'N'; value = '';
                        lower = lo[_s]; upper = up[_s]; lo_inf = (lo[_s] = .); hi_inf = (up[_s] = .);
                        part = ''; part2 = '';
                        if lo[_s] ne . then do;
                            %seg_fmtnum(x=lo[_s], into=_v1)
                            part = catx(' ', sname[_s], '>=', _v1);
                        end;
                        if up[_s] ne . then do;
                            %seg_fmtnum(x=up[_s], into=_v2)
                            part2 = catx(' ', sname[_s], '<', _v2);
                        end;
                        label = catx(' AND ', part, part2);
                        num_text = catx(' AND ', num_text, part, part2);
                        output &out_rules;
                    end;
                end;
            end;

            %if %upcase(&mode) = SIMPLIFY %then %do;
                Segment_Definition = catx(' AND ', eq_text, neg_text, num_text);
            %end;
            %else %do;
                Segment_Definition = catx(' AND ', cat_text, num_text);
            %end;
            if missing(Segment_Definition) then Segment_Definition = "&root_label";
            output &out_defs;
        end;
    run;

%mend seg_tree_rules;
