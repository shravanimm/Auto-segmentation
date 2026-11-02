/* ============================================================================
   seg_km_fit.sas
   K-Means in Base SAS, following sklearn.cluster.KMeans:
     * n_init independent runs, keep the lowest inertia
     * k-means++ seeding (D^2-weighted; the greedy multi-trial variant of
       sklearn is simplified to one trial)
     * Lloyd iterations until the summed squared centre shift <=
       tol * mean(column variance)   (sklearn's tolerance rule), max maxiter
     * empty cluster -> its centre moves to the point farthest from its centre
     * final labels = nearest final centre (lowest index on ties)
   WHAT IS NOT REPRODUCIBLE: sklearn's random stream. Different seeds/streams
   give different local optima, so cluster identities (and everything derived,
   incl. the chosen k) are statistically equivalent to Python, not identical.
   PROC FASTCLUS/KCLUS were deliberately not used: their seeding and
   convergence rules differ from sklearn's and are harder to reason about.

   Size limit: the matrix is held in memory (n*d*8 bytes) and the cost is
   O(n*k*d*iters*n_init). Python switches to MiniBatchKMeans above 200,000 rows;
   above that use CAS (PROC KCLUS) - this macro stops with an ERROR above 5e7 cells.
   data : _rid, d1..dD            out_lab: _rid, lab (0..k-1)   out_cen: cid, c1..cD
   ============================================================================ */
%macro seg_km_fit(data=, n=, d=, k=, seed=, n_init=10, maxiter=300, tol=0.0001,
                  out_lab=, out_cen=);

    %if %sysevalf(&n * &d > 5e7) %then %do;
        %put ERROR: seg_km_fit - &n x &d matrix too large for the in-memory K-Means - use CAS PROC KCLUS.;
        %return;
    %end;

    data &out_lab(keep=_rid lab) &out_cen(keep=cid c1-c&d);
        array X    [&n, &d]  _temporary_;
        array rid  [&n]      _temporary_;
        array cen  [&k, &d]  _temporary_;
        array nsum [&k, &d]  _temporary_;
        array bcen [&k, &d]  _temporary_;
        array cnt  [&k]      _temporary_;
        array lb   [&n]      _temporary_;
        array blb  [&n]      _temporary_;
        array dmin [&n]      _temporary_;
        array dv   [&d]      d1-d&d;
        array oc   [&d]      c1-c&d;

        i = 0;
        do until(_e);
            set &data end=_e;
            i + 1;
            rid[i] = _rid;
            do j = 1 to &d; X[i, j] = dv[j]; end;
        end;

        /* tolerance = tol * mean over columns of the population variance */
        tv = 0;
        do j = 1 to &d;
            m = 0; do i = 1 to &n; m + X[i, j]; end; m = m / &n;
            v = 0; do i = 1 to &n; v + (X[i, j] - m) ** 2; end; tv + v / &n;
        end;
        tolabs = &tol * tv / &d;

        call streaminit(&seed);
        bestin = 1e300;

        do r = 1 to &n_init;
            /* ---- k-means++ ---- */
            c1i = max(1, ceil(rand('uniform') * &n));
            do j = 1 to &d; cen[1, j] = X[c1i, j]; end;
            do i = 1 to &n;
                dd = 0; do j = 1 to &d; dd + (X[i, j] - cen[1, j]) ** 2; end;
                dmin[i] = dd;
            end;
            do c = 2 to &k;
                tot = 0; do i = 1 to &n; tot + dmin[i]; end;
                u = rand('uniform') * tot; cum = 0; pick = &n;
                do i = 1 to &n;
                    cum + dmin[i];
                    if cum >= u then do; pick = i; leave; end;
                end;
                do j = 1 to &d; cen[c, j] = X[pick, j]; end;
                do i = 1 to &n;
                    dd = 0; do j = 1 to &d; dd + (X[i, j] - cen[c, j]) ** 2; end;
                    if dd < dmin[i] then dmin[i] = dd;
                end;
            end;

            /* ---- Lloyd ---- */
            do it = 1 to &maxiter;
                do c = 1 to &k; cnt[c] = 0; do j = 1 to &d; nsum[c, j] = 0; end; end;
                do i = 1 to &n;
                    bd = 1e300; bc = 1;
                    do c = 1 to &k;
                        dd = 0; do j = 1 to &d; dd + (X[i, j] - cen[c, j]) ** 2; end;
                        if dd < bd then do; bd = dd; bc = c; end;
                    end;
                    lb[i] = bc; dmin[i] = bd; cnt[bc] + 1;
                    do j = 1 to &d; nsum[bc, j] + X[i, j]; end;
                end;
                shift = 0;
                do c = 1 to &k;
                    if cnt[c] = 0 then do;                   /* empty cluster: farthest point */
                        far = 1; fd = -1;
                        do i = 1 to &n; if dmin[i] > fd then do; fd = dmin[i]; far = i; end; end;
                        do j = 1 to &d; nsum[c, j] = X[far, j]; end;
                        cnt[c] = 1; dmin[far] = 0;
                    end;
                    do j = 1 to &d;
                        nw = nsum[c, j] / cnt[c];
                        shift + (nw - cen[c, j]) ** 2;
                        cen[c, j] = nw;
                    end;
                end;
                if shift <= tolabs then leave;
            end;

            /* ---- final labels + inertia ---- */
            inertia = 0;
            do i = 1 to &n;
                bd = 1e300; bc = 1;
                do c = 1 to &k;
                    dd = 0; do j = 1 to &d; dd + (X[i, j] - cen[c, j]) ** 2; end;
                    if dd < bd then do; bd = dd; bc = c; end;
                end;
                lb[i] = bc; inertia + bd;
            end;
            if inertia < bestin then do;
                bestin = inertia;
                do i = 1 to &n; blb[i] = lb[i]; end;
                do c = 1 to &k; do j = 1 to &d; bcen[c, j] = cen[c, j]; end; end;
            end;
        end;

        do i = 1 to &n; _rid = rid[i]; lab = blb[i] - 1; output &out_lab; end;
        do c = 1 to &k;
            cid = c - 1;
            do j = 1 to &d; oc[j] = bcen[c, j]; end;
            output &out_cen;
        end;
        stop;
    run;

%mend seg_km_fit;
