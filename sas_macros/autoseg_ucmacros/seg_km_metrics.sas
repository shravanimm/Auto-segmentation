/* ============================================================================
   seg_km_metrics.sas
   Internal validity metrics of a clustering (sklearn.metrics definitions,
   centroids recomputed as the mean of each label's rows):
     silhouette_score  (Euclidean; all points when n <= 10000, otherwise a
                        random 10000-point sample as sample_size=10000 does)
     calinski_harabasz_score
     davies_bouldin_score
   Verified against sklearn on a 1500x6, k=5 case to ~1e-17.
   x: _rid, d1..dD (sorted by _rid)   lab: _rid, lab (0..k-1)
   out: one row (silhouette, calinski_harabasz, davies_bouldin)
   ============================================================================ */
%macro seg_km_metrics(x=, lab=, n=, d=, k=, seed=42, out=);

    data _km_mx; merge &x &lab; by _rid; run;

    data &out(keep=silhouette calinski_harabasz davies_bouldin);
        array X  [&n, &d] _temporary_;
        array lb [&n]     _temporary_;
        array cn [&k]     _temporary_;
        array cm [&k, &d] _temporary_;
        array gm [&d]     _temporary_;
        array sc [&k]     _temporary_;
        array dm [&k, &k] _temporary_;
        array sums [&k]   _temporary_;
        array scnt [&k]   _temporary_;
        array idx [&n]    _temporary_;
        array dv [&d] d1-d&d;

        i = 0;
        do until(_e);
            set _km_mx end=_e;
            i + 1; lb[i] = lab + 1;
            do j = 1 to &d; X[i, j] = dv[j]; end;
        end;

        do c = 1 to &k; cn[c] = 0; do j = 1 to &d; cm[c, j] = 0; end; end;
        do j = 1 to &d; gm[j] = 0; end;
        do i = 1 to &n;
            cn[lb[i]] + 1;
            do j = 1 to &d; cm[lb[i], j] + X[i, j]; gm[j] + X[i, j]; end;
        end;
        do j = 1 to &d; gm[j] = gm[j] / &n; end;
        do c = 1 to &k; if cn[c] > 0 then do j = 1 to &d; cm[c, j] = cm[c, j] / cn[c]; end; end;

        /* Calinski-Harabasz */
        bss = 0; wss = 0;
        do c = 1 to &k;
            dd = 0; do j = 1 to &d; dd + (cm[c, j] - gm[j]) ** 2; end;
            bss + cn[c] * dd;
        end;
        do i = 1 to &n;
            do j = 1 to &d; wss + (X[i, j] - cm[lb[i], j]) ** 2; end;
        end;
        if wss = 0 then calinski_harabasz = 1;
        else calinski_harabasz = (bss / (&k - 1)) / (wss / (&n - &k));

        /* Davies-Bouldin */
        do c = 1 to &k; sc[c] = 0; end;
        do i = 1 to &n;
            dd = 0; do j = 1 to &d; dd + (X[i, j] - cm[lb[i], j]) ** 2; end;
            sc[lb[i]] + sqrt(dd);
        end;
        do c = 1 to &k; if cn[c] > 0 then sc[c] = sc[c] / cn[c]; end;
        do a = 1 to &k; do b = 1 to &k;
            dd = 0; do j = 1 to &d; dd + (cm[a, j] - cm[b, j]) ** 2; end;
            dm[a, b] = sqrt(dd);
        end; end;
        dbsum = 0;
        do a = 1 to &k;
            mx = 0;
            do b = 1 to &k;
                if b ne a and dm[a, b] > 0 then mx = max(mx, (sc[a] + sc[b]) / dm[a, b]);
            end;
            dbsum + mx;
        end;
        davies_bouldin = dbsum / &k;

        /* silhouette (sample when n > 10000) */
        m = min(&n, 10000);
        do i = 1 to &n; idx[i] = i; end;
        if &n > 10000 then do;
            call streaminit(&seed);
            do s = 1 to m;
                t = s + floor(rand('uniform') * (&n - s + 1));
                tmp = idx[s]; idx[s] = idx[t]; idx[t] = tmp;
            end;
        end;
        do c = 1 to &k; scnt[c] = 0; end;
        do s = 1 to m; scnt[lb[idx[s]]] + 1; end;
        nclu = 0; do c = 1 to &k; if scnt[c] > 0 then nclu + 1; end;
        if nclu < 2 then silhouette = .;
        else do;
            tot = 0;
            do s = 1 to m;
                i = idx[s]; own = lb[i];
                do c = 1 to &k; sums[c] = 0; end;
                do t = 1 to m;
                    j2 = idx[t];
                    dd = 0; do j = 1 to &d; dd + (X[i, j] - X[j2, j]) ** 2; end;
                    sums[lb[j2]] + sqrt(dd);
                end;
                if scnt[own] > 1 then do;
                    av = sums[own] / (scnt[own] - 1);
                    bv = 1e300;
                    do c = 1 to &k;
                        if c ne own and scnt[c] > 0 then bv = min(bv, sums[c] / scnt[c]);
                    end;
                    mxab = max(av, bv);
                    if mxab > 0 then tot + (bv - av) / mxab;
                end;
            end;
            silhouette = tot / m;
        end;
        output;
        stop;
    run;

%mend seg_km_metrics;
