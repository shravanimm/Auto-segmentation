/* ============================================================================
   seg_fb_bins_num.sas
   Feature Binning bins for ONE numeric feature (build_numeric_bins):
     * a "<f> is Missing" bin if the missing share of dev >= min_bin_pct
     * supervised bins from a best-first CART on the non-missing dev rows
       (DecisionTreeClassifier(max_leaf_nodes=max_bins,
        min_samples_leaf=max(int(N*min_bin_pct), 20)), gini):
         - only attempted when #non-missing >= 2*min_samples_leaf
         - rows enter as float32; thresholds are midpoints of float32 values
         - repeatedly split the leaf with the largest impurity improvement until
           max_bins leaves (verified identical to sklearn on the demo features)
       Bin j = (t_j-1, t_j] (lower exclusive, upper INCLUSIVE); labels use the
       thresholds rounded to 3 dp like Python ("f <= 61.885", "a < f <= b").
   Appends to _fb_bin (bin_id, feat_idx, feature, btype, lower, upper, lo_inf,
   hi_inf, label). Requires global sg_fb_nbin (running bin counter).
   ============================================================================ */
%macro seg_fb_bins_num(f=, i=, max_bins=8, min_bin_pct=0.01);

    %local nmiss nn minleaf m k;

    proc sql noprint; select sum(missing(&f)) into :nmiss trimmed from _sg_dev; quit;
    %if %sysevalf(&nmiss / &sg_ndev >= &min_bin_pct) %then %do;
        %let sg_fb_nbin = %eval(&sg_fb_nbin + 1);
        data _fb_b1;
            length feature $64 btype $10 label $400;
            bin_id = &sg_fb_nbin; feat_idx = &i; feature = "&f"; btype = 'missing';
            lower = .; upper = .; lo_inf = 0; hi_inf = 0; label = "&f is Missing";
        run;
        proc append base=_fb_bin data=_fb_b1 force; run;
    %end;

    data _fb_x;
        set _sg_dev(keep=&f _y);
        where not missing(&f);
        _t = &f;
        %seg_f32(x=_t, into=_v)
    run;
    %let nn = %seg_nobs(_fb_x);
    data _null_; call symputx('minleaf', max(int(&sg_ndev * &min_bin_pct), 20), 'L'); run;

    %if &nn >= %eval(2 * &minleaf) %then %do;

        proc sql;
            create table _fb_d as
            select _v as v, count(*) as ni, sum(_y) as pi from _fb_x group by _v order by _v;
        quit;
        %let m = %seg_nobs(_fb_d);

        /* ---- best-first splitting over the distinct values ---- */
        data _fb_thr(keep=thr);
            array vv [&m] _temporary_;
            array cn [0:&m] _temporary_;
            array cp [0:&m] _temporary_;
            array lo [&max_bins] _temporary_;
            array hi [&max_bins] _temporary_;
            array im [&max_bins] _temporary_;
            array sp [&max_bins] _temporary_;
            cn[0] = 0; cp[0] = 0; ix = 0;
            do until(_e);
                set _fb_d end=_e;
                ix + 1; vv[ix] = v; cn[ix] = cn[ix - 1] + ni; cp[ix] = cp[ix - 1] + pi;
            end;
            nl = 1; lo[1] = 1; hi[1] = &m; L = 1; link ev;
            do while(nl < &max_bins);
                pick = 0; bimp = -1e300;
                do q = 1 to nl;
                    if sp[q] > 0 then if im[q] > bimp then do; bimp = im[q]; pick = q; end;
                end;
                if pick = 0 then leave;
                s = sp[pick];
                thr = vv[s] / 2 + vv[s + 1] / 2;
                output;
                hb = hi[pick];
                hi[pick] = s; nl + 1; lo[nl] = s + 1; hi[nl] = hb;
                L = pick; link ev;
                L = nl;   link ev;
            end;
            stop;
        ev:
            a = lo[L]; b = hi[L];
            nt = cn[b] - cn[a - 1]; pt = cp[b] - cp[a - 1];
            im[L] = .; sp[L] = 0;
            if nt >= 2 * &minleaf and pt > 0 and pt < nt then do;
                par = (pt ** 2 + (nt - pt) ** 2) / nt; bp = -1e300; bs = 0;
                do ii = a to b - 1;
                    if vv[ii + 1] > vv[ii] + 1e-7 then do;
                        nl_ = cn[ii] - cn[a - 1]; nr_ = nt - nl_;
                        if nl_ >= &minleaf and nr_ >= &minleaf then do;
                            pl = cp[ii] - cp[a - 1]; pr = pt - pl;
                            prox = (pl ** 2 + (nl_ - pl) ** 2) / nl_ + (pr ** 2 + (nr_ - pr) ** 2) / nr_;
                            if prox > bp then do; bp = prox; bs = ii; end;
                        end;
                    end;
                end;
                if bs > 0 then do; im[L] = bp - par; sp[L] = bs; end;
            end;
            return;
        run;
        proc sort data=_fb_thr; by thr; run;
        %let k = %seg_nobs(_fb_thr);

        /* ---- thresholds -> intervals (lower, upper] ---- */
        %if &k = 0 %then %do;
            data _fb_b2;
                length feature $64 btype $10 label $400;
                bin_id = &sg_fb_nbin + 1; feat_idx = &i; feature = "&f"; btype = 'numeric';
                lower = .; upper = .; lo_inf = 1; hi_inf = 1; label = "&f (all non-missing values)";
            run;
        %end;
        %else %do;
            data _fb_b2(keep=bin_id feat_idx feature btype lower upper lo_inf hi_inf label);
                array tt [&k] _temporary_;
                length feature $64 btype $10 label $400 _a _b $40;
                ix = 0;
                do until(_e);
                    set _fb_thr end=_e;
                    ix + 1; tt[ix] = thr;
                end;
                do j = 1 to &k + 1;
                    bin_id = &sg_fb_nbin + j; feat_idx = &i; feature = "&f"; btype = 'numeric';
                    lo_inf = (j = 1); hi_inf = (j = &k + 1);
                    /* NOT ifn(): it evaluates both arguments, so tt[0] / tt[k+1] would be read */
                    if lo_inf then lower = .; else lower = tt[j - 1];
                    if hi_inf then upper = .; else upper = tt[j];
                    if not lo_inf then do;
                        _a = strip(put(round(lower, 0.001), best15.));
                        if index(_a, '.') = 0 and index(upcase(_a), 'E') = 0 then _a = cats(_a, '.0');
                    end;
                    if not hi_inf then do;
                        _b = strip(put(round(upper, 0.001), best15.));
                        if index(_b, '.') = 0 and index(upcase(_b), 'E') = 0 then _b = cats(_b, '.0');
                    end;
                    if lo_inf then label = catx(' ', "&f", '<=', _b);
                    else if hi_inf then label = catx(' ', "&f", '>', _a);
                    else label = catx(' ', _a, '<', "&f", '<=', _b);
                    output;
                end;
                stop;
            run;
        %end;
        proc append base=_fb_bin data=_fb_b2 force; run;
        %let sg_fb_nbin = %eval(&sg_fb_nbin + &k + 1);
    %end;

%mend seg_fb_bins_num;
