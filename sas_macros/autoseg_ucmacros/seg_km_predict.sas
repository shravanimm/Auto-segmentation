/* ============================================================================
   seg_km_predict.sas
   Nearest-centre assignment (KMeans.predict): lowest cluster index on ties.
   data: _rid, d1..dD     cen: cid (0..k-1), c1..cD     out: _rid, lab
   ============================================================================ */
%macro seg_km_predict(data=, cen=, d=, k=, out=);

    data &out(keep=_rid lab);
        array cc [&k, &d] _temporary_;
        array dv [&d] d1-d&d;
        array oc [&d] c1-c&d;
        if _n_ = 1 then do;
            do until(_e);
                set &cen end=_e;
                do j = 1 to &d; cc[cid + 1, j] = oc[j]; end;
            end;
        end;
        set &data;
        bd = 1e300; bc = 0;
        do c = 1 to &k;
            dd = 0; do j = 1 to &d; dd + (dv[j] - cc[c, j]) ** 2; end;
            if dd < bd then do; bd = dd; bc = c - 1; end;
        end;
        lab = bc;
    run;

%mend seg_km_predict;
