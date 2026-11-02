/* ============================================================================
   seg_membership.sas
   Row membership of candidate segments, as a LONG table (one row per
   candidate x member row), plus the requested columns of the member rows.

   Mode 1 (sg_premem = N, AutoSlicer): a candidate row of _sg_cand carries
   c1..cN where c<i> = pred_id constrained on feature i, or 0 = unconstrained.
   A data row (with _b1.._bN from seg_as_predicates) is a member iff, for every
   i,  c<i> = 0  OR  c<i> = _b<i>.   (missing/unseen => _b = -1 => never equal)

   Mode 2 (sg_premem = Y; trees, clusters, bins): the technique has already
   written _sg_memb_dev / _sg_memb_mon (cand_id,_rid); candidates are the ones
   listed in &cand.

   side : dev | mon      cand : candidate table (cand_id [, c1..cN])
   cols : columns copied from _sg_<side> into the long table
   Requires: sg_nf (mode 1), sg_premem
   Scale note: mode 1 is a candidates x rows join - fine for the demo/5k-row
   data; for 1M-row production data run it in CAS (same logic).
   ============================================================================ */
%macro seg_membership(side=, cand=, out=, cols=_rid _y _s _w);

    %local i collist;
    %let collist = ;
    %do i = 1 %to %sysfunc(countw(&cols, %str( )));
        %let collist = &collist, r.%scan(&cols, &i, %str( ));
    %end;

    %if &sg_premem = Y %then %do;
        proc sql;
            create table &out as
            select m.cand_id &collist
            from _sg_memb_&side m, _sg_&side r
            where m._rid = r._rid
              and m.cand_id in (select cand_id from &cand);
        quit;
    %end;
    %else %do;
        proc sql;
            create table &out as
            select c.cand_id &collist
            from &cand c, _sg_&side r
            where 1 = 1
            %do i = 1 %to &sg_nf;
                and (c.c&i = 0 or c.c&i = r._b&i)
            %end;
            ;
        quit;
    %end;

%mend seg_membership;
