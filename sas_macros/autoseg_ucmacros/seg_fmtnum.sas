/* ============================================================================
   seg_fmtnum.sas
   DATA-step statement macro: formats a numeric threshold for DISPLAY, like
   utils/preprocessing.format_number: round to 2 dp; integers get thousands
   separators ("60,810"), others drop trailing zeros ("44.5").

   DISPLAY ONLY. Exact thresholds are always stored separately in the rules
   table (seg_*_rules) - rounded text is not a faithful rule definition.
   Known tie divergence: SAS ROUND() rounds exact-binary-near-ties away from
   zero (33.005 -> 33.01), Python rounds on the exact binary value (-> 33).

   Usage inside a DATA step:   %seg_fmtnum(x=edge, into=lbl)
   ============================================================================ */
%macro seg_fmtnum(x=, into=);
    _fr = round(&x, 0.01);
    if abs(_fr - round(_fr)) < 1e-9 then &into = strip(put(round(_fr), comma32.));
    else do;
        &into = strip(put(_fr, comma32.2));
        if substr(&into, length(&into), 1) = '0' then &into = substr(&into, 1, length(&into) - 1);
    end;
%mend seg_fmtnum;
