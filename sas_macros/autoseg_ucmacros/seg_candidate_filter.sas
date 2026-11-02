/* ============================================================================
   seg_candidate_filter.sas
   Cheap first-pass gates, run BEFORE the expensive per-candidate metrics:
     passes_support_filter : n_dev, n_mon >= min_abs_count ; pct_dev, pct_mon >=
                             min_support ; pct_dev, pct_mon <= max_segment_pct
     passes_event_count    : events in dev and in mon >= min_events_per_slice
   (core/candidate_filtering.py). Output = the surviving candidate rows
   (cand_id, depth, c1..cN, ...) copied from &cand.
   Requires: sg_ndev sg_nmon sg_minabs sg_minsup sg_maxpct sg_minev
   ============================================================================ */
%macro seg_candidate_filter(cand=, out=);

    %seg_membership(side=dev, cand=&cand, out=_sg_ml_dev, cols=_y);
    %seg_membership(side=mon, cand=&cand, out=_sg_ml_mon, cols=_y);

    proc sql;
        create table _sg_pass as
        select d.cand_id
        from (select cand_id, count(*) as n, sum(_y) as x from _sg_ml_dev group by cand_id) d
             inner join
             (select cand_id, count(*) as n, sum(_y) as x from _sg_ml_mon group by cand_id) m
             on d.cand_id = m.cand_id
        where d.n >= &sg_minabs and m.n >= &sg_minabs
          and d.n / &sg_ndev >= &sg_minsup and m.n / &sg_nmon >= &sg_minsup
          and d.n / &sg_ndev <= &sg_maxpct and m.n / &sg_nmon <= &sg_maxpct
          and d.x >= &sg_minev and m.x >= &sg_minev;

        create table &out as
        select * from &cand where cand_id in (select cand_id from _sg_pass)
        order by cand_id;
    quit;

%mend seg_candidate_filter;
