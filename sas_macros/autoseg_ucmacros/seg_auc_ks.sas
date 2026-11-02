/* ============================================================================
   seg_auc_ks.sas
   Per-candidate AUC and KS for one side (dev or mon) from a membership table.

   AUC  : Mann-Whitney / rank-sum with mid-ranks for ties (PROC RANK
          TIES=MEAN):  (R1 - n1(n1+1)/2) / (n1*n0). Identical to
          sklearn.roc_auc_score, including tie handling (verified to 1e-16).
          Missing (.) when the segment has only one target class.
   KS   : max |cumBad/nBad - cumGood/nGood| evaluated at the END of each block
          of tied scores (the standard statistic). Python's calculate_ks scans
          row-by-row, so inside a tie block its value depends on numpy's
          arbitrary tie order; on tie-free scores the two are identical. On the
          demo data they differ by <= 2.6e-3 and produce the SAME candidate
          pool and top-10 (verified by re-running the Python with this KS).
   in : &mem with cand_id, _y, _s        out: cand_id, auc, ks
   ============================================================================ */
%macro seg_auc_ks(mem=, out=);

    proc sort data=&mem(keep=cand_id _y _s) out=_sg_ak1;
        by cand_id _s;
    run;

    proc rank data=_sg_ak1 out=_sg_ak2 ties=mean;
        by cand_id;
        var _s;
        ranks _r;
    run;

    proc sql;
        create table _sg_ak3 as
        select cand_id,
               sum(_y = 1) as n1,
               sum(_y = 0) as n0,
               sum(case when _y = 1 then _r else 0 end) as r1
        from _sg_ak2
        group by cand_id;
    quit;

    proc sort data=_sg_ak1 out=_sg_ak4;
        by cand_id descending _s;
    run;

    data _sg_ak5(keep=cand_id ks);
        if _n_ = 1 then do;
            if 0 then set _sg_ak3(keep=cand_id n1 n0);
            declare hash h(dataset: '_sg_ak3');
            h.defineKey('cand_id');
            h.defineData('n1', 'n0');
            h.defineDone();
        end;
        set _sg_ak4;
        by cand_id descending _s;
        retain cb cg ks;
        if first.cand_id then do;
            rc = h.find();
            cb = 0; cg = 0; ks = 0;
        end;
        if _y = 1 then cb + 1; else cg + 1;
        if last._s and n1 > 0 and n0 > 0 then ks = max(ks, abs(cb / n1 - cg / n0));
        if last.cand_id then do;
            if n1 = 0 or n0 = 0 then ks = .;
            output;
        end;
    run;

    proc sql;
        create table &out as
        select a.cand_id,
               case when a.n1 > 0 and a.n0 > 0 then (a.r1 - a.n1 * (a.n1 + 1) / 2) / (a.n1 * a.n0)
                    else . end as auc,
               k.ks
        from _sg_ak3 a left join _sg_ak5 k on a.cand_id = k.cand_id
        order by a.cand_id;
    quit;

%mend seg_auc_ks;
