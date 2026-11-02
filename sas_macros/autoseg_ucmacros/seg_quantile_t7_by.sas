/* ============================================================================
   seg_quantile_t7_by.sas
   Group-wise quantiles that are BIT-COMPATIBLE with numpy.quantile (linear /
   "type 7") + numpy.linspace(0,1,nbins+1).

   Why not PROC MEANS/UNIVARIATE: they only offer PCTLDEF 1-5, never type 7.
   Why bit-compatible: data values sit exactly on edges (e.g. dti = 51.81), so a
   last-bit difference moves whole tie blocks between bins. numpy computes
       h = (n-1)*p ; lo = floor(h) ; g = h-lo
       q = b-(b-a)*(1-g)  if g >= 0.5  else  a+(b-a)*g        (a=x[lo], b=x[lo+1])
   with p_j = j*(1/nbins) (linspace) and p_nbins = 1.0. This macro copies that.

   in    : dataset SORTED by &by &var, no missing &var
   by    : ONE by-variable
   nbins : number of intervals (quantiles q0..q&nbins are returned)
   out   : &by, n, q0 ... q&nbins (one row per by-group)
   ============================================================================ */
%macro seg_quantile_t7_by(in=, by=, var=, nbins=, out=);

    proc sql noprint;
        create table _sg_qn as
        select &by, count(*) as _qn from &in group by &by order by &by;
    quit;

    data &out(keep=&by n q0-q&nbins);
        merge &in(keep=&by &var) _sg_qn;
        by &by;
        array q [0:&nbins] q0-q&nbins;
        array xl[0:&nbins] _xl0-_xl&nbins;
        array xh[0:&nbins] _xh0-_xh&nbins;
        array lo[0:&nbins] _lo0-_lo&nbins;
        array gm[0:&nbins] _gm0-_gm&nbins;
        retain _xl0-_xl&nbins _xh0-_xh&nbins _lo0-_lo&nbins _gm0-_gm&nbins _k;

        if first.&by then do;
            _k = 0;
            do _j = 0 to &nbins;
                _p = ifn(_j = &nbins, 1, _j * (1 / &nbins));
                _h = (_qn - 1) * _p;
                lo[_j] = floor(_h);
                gm[_j] = _h - lo[_j];
                xl[_j] = .;
                xh[_j] = .;
            end;
        end;
        else _k + 1;

        do _j = 0 to &nbins;
            if _k = lo[_j] then xl[_j] = &var;
            if _k = min(lo[_j] + 1, _qn - 1) then xh[_j] = &var;
        end;

        if last.&by then do;
            n = _qn;
            do _j = 0 to &nbins;
                _a = xl[_j];
                _b = xh[_j];
                _d = _b - _a;
                q[_j] = ifn(gm[_j] >= 0.5, _b - _d * (1 - gm[_j]), _a + _d * gm[_j]);
            end;
            output;
        end;
    run;

%mend seg_quantile_t7_by;
