/* ============================================================================
   seg_bh.sas
   Benjamini-Hochberg FDR adjustment (metrics/significance.adjust_p_values_bh).
   Missing p-values are excluded from the family and stay missing. Tied
   p-values all receive the adjusted value of the highest rank in the tie
   (reverse cumulative minimum), so the result does not depend on tie order.
   in : table with cand_id and &pvar     out: cand_id, &adjvar
   ============================================================================ */
%macro seg_bh(in=, pvar=, adjvar=, out=);

    %local nv;

    data _sg_bh_a(keep=cand_id p);
        set &in(keep=cand_id &pvar rename=(&pvar=p));
        if not missing(p);
    run;
    %let nv = %seg_nobs(_sg_bh_a);

    %if &nv = 0 %then %do;
        data &out; length cand_id 8 &adjvar 8; stop; run;
    %end;
    %else %do;
        proc sort data=_sg_bh_a; by p cand_id; run;

        data _sg_bh_b;
            set _sg_bh_a;
            rnk = _n_;
            v   = p * &nv / rnk;
        run;

        proc sort data=_sg_bh_b; by descending rnk; run;

        data _sg_bh_c(keep=cand_id &adjvar);
            set _sg_bh_b;
            retain cm 1e300;
            cm = min(cm, v);
            &adjvar = min(cm, 1);
        run;

        proc sort data=_sg_bh_c out=&out; by cand_id; run;
    %end;

%mend seg_bh;
