/* ============================================================================
   seg_ks_shift.sas
   Per-candidate two-sample KS test on the model SCORE, dev rows vs mon rows
   (metrics/significance.ks_score_shift_pvalue -> scipy.stats.ks_2samp).

   D = max |F_dev(x) - F_mon(x)| over the pooled distinct scores.
   p-value: asymptotic Kolmogorov distribution with Stephens' finite-sample
   correction  lambda = (sqrt(en) + 0.12 + 0.11/sqrt(en)) * D,
               p = 2 * sum_{k>=1} (-1)^(k-1) exp(-2 k^2 lambda^2),  en = n*m/(n+m).
   DEVIATION: scipy uses the EXACT p-value when max(n,m) <= 10000; this is the
   asymptotic form. On the 80-candidate demo pool the largest |difference| is
   0.019 and it flips 0 of 80 Statistically_Significant flags. The p-value only
   feeds the significance flag (BH-adjusted, alpha 0.05), never a score.
   cnt : table with cand_id, n_dev, n_mon        out: cand_id, ks_stat, score_shift_pvalue
   ============================================================================ */
%macro seg_ks_shift(mem_dev=, mem_mon=, cnt=, out=);

    data _sg_kh1;
        set &mem_dev(keep=cand_id _s) &mem_mon(keep=cand_id _s in=_im);
        src = _im;
        if not missing(_s);
    run;

    proc sort data=_sg_kh1; by cand_id _s; run;

    data &out(keep=cand_id ks_stat score_shift_pvalue);
        if _n_ = 1 then do;
            if 0 then set &cnt(keep=cand_id n_dev n_mon);
            declare hash h(dataset: "&cnt");
            h.defineKey('cand_id');
            h.defineData('n_dev', 'n_mon');
            h.defineDone();
        end;
        set _sg_kh1;
        by cand_id _s;
        retain cd cm ks_stat;
        if first.cand_id then do;
            rc = h.find();
            cd = 0; cm = 0; ks_stat = 0;
        end;
        if src = 0 then cd + 1; else cm + 1;
        if last._s then ks_stat = max(ks_stat, abs(cd / n_dev - cm / n_mon));
        if last.cand_id then do;
            if n_dev < 2 or n_mon < 2 then score_shift_pvalue = .;
            else do;
                en  = sqrt(n_dev * n_mon / (n_dev + n_mon));
                lam = (en + 0.12 + 0.11 / en) * ks_stat;
                if lam < 0.27 then p = 1;
                else do;
                    p = 0;
                    do k = 1 to 100;
                        p = p + 2 * ((-1) ** (k - 1)) * exp(-2 * k * k * lam * lam);
                    end;
                end;
                score_shift_pvalue = min(1, max(0, p));
            end;
            output;
        end;
    run;

%mend seg_ks_shift;
