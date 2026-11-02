/* ============================================================================
   seg_cand_rules.sas
   Turns candidate rows (c1..cN) into
     &out_rules : long rule table - the EXACT, machine-readable definition
                  (cand_id, feature, ptype, lower, upper, lo_inf, hi_inf, value)
                  numeric: lower <= x < upper (missing bound = open)
                  character: x = value
     &out_defs  : cand_id, Segment_Definition ("a AND b", labels ordered by
                  feature NAME, as the Python code sorts them)
   Display text is rounded (see seg_fmtnum); the rules table is authoritative.
   ============================================================================ */
%macro seg_cand_rules(cand=, out_rules=, out_defs=);

    data _sg_cr1(keep=cand_id feat_idx pred_id);
        set &cand;
        array c [&sg_nf] c1-c&sg_nf;
        do feat_idx = 1 to &sg_nf;
            if c[feat_idx] > 0 then do;
                pred_id = c[feat_idx];
                output;
            end;
        end;
    run;

    proc sql;
        create table &out_rules as
        select a.cand_id, p.feature, p.feat_idx, p.ptype, p.lower, p.upper, p.lo_inf, p.hi_inf,
               p.value, p.label
        from _sg_cr1 a inner join _sg_pred p on a.pred_id = p.pred_id
        order by a.cand_id, p.feature;
    quit;

    data &out_defs(keep=cand_id Segment_Definition);
        set &out_rules;
        by cand_id;
        length Segment_Definition $1000;
        retain Segment_Definition;
        if first.cand_id then Segment_Definition = label;
        else Segment_Definition = catx(' AND ', Segment_Definition, label);
        if last.cand_id then output;
    run;

%mend seg_cand_rules;
