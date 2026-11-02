/* ============================================================================
   seg_rank_dedup.sas
   Significance-first ranking + Jaccard/containment de-duplication
   (core/candidate_ranking.rank_records_significance_first and
    core/candidate_deduplication.deduplicate_by_jaccard).

   Order: Statistically_Significant desc, Severity_Score desc, then original
   evaluation order (cand_id asc) - the same as Python's stable sort.
   A candidate is dropped when, against any already-kept candidate (monitoring
   rows), jaccard >= overlap OR containment(cand in kept) >= 0.90 OR
   containment(kept in cand) >= 0.90. Selection stops at pool_size kept.
   Pairwise monitoring-row intersections come from one self-join on _rid.

   in      : scored pool (cand_id, n_mon, Statistically_Significant, Severity_Score)
   sortby  : ranking key; Feature Binning ranks by its own final score instead
   mem_mon : cand_id, _rid for every pool candidate
   out     : kept candidates, in rank order, with column dedup_rank (1..)
   ============================================================================ */
%macro seg_rank_dedup(in=, mem_mon=, out=, overlap=0.70, containment=0.90, pool_size=30, dedup=Y,
                      sortby=%str(descending Statistically_Significant descending Severity_Score cand_id));

    proc sort data=&in out=_sg_rk1;
        by &sortby;
    run;

    /* dedup=N (Drift Tree, K-Means): ranking only - Python never de-duplicates there */
    %if %upcase(&dedup) ne Y %then %do;
        data &out;
            set _sg_rk1;
            dedup_rank = _n_;
        run;
        %return;
    %end;

    proc sql;
        create table _sg_pairs as
        select a.cand_id as ca, b.cand_id as cb, count(*) as inter
        from &mem_mon a inner join &mem_mon b
             on a._rid = b._rid and a.cand_id < b.cand_id
        group by a.cand_id, b.cand_id;
    quit;

    data &out;
        if _n_ = 1 then do;
            if 0 then set _sg_pairs;
            declare hash hp(dataset: '_sg_pairs');
            hp.defineKey('ca', 'cb');
            hp.defineData('inter');
            hp.defineDone();
        end;
        set _sg_rk1;
        array kc [&pool_size] _temporary_;
        array kn [&pool_size] _temporary_;
        retain nk 0;
        redundant = 0;
        do _k = 1 to nk;
            ca = min(cand_id, kc[_k]);
            cb = max(cand_id, kc[_k]);
            if hp.find() ne 0 then inter = 0;
            _union = n_mon + kn[_k] - inter;
            _jac   = ifn(_union > 0, inter / _union, 0);
            _cc    = ifn(n_mon > 0, inter / n_mon, 0);
            _ck    = ifn(kn[_k] > 0, inter / kn[_k], 0);
            if _jac >= &overlap or _cc >= &containment or _ck >= &containment then do;
                redundant = 1;
                leave;
            end;
        end;
        if redundant = 0 and nk < &pool_size then do;
            nk + 1;
            kc[nk] = cand_id;
            kn[nk] = n_mon;
            dedup_rank = nk;
            output;
        end;
        drop ca cb inter redundant _k _union _jac _cc _ck nk;
    run;

%mend seg_rank_dedup;
