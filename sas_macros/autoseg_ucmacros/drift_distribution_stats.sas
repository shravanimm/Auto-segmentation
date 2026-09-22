/* ============================================================================
   drift_distribution_stats.sas
   (was %drift_tech6_distribution_stats in the old 20_drift_macros.sas)

   Quantile Shift, Std Deviation Drift, CV Drift, Boundary (min/max) Drift,
   Kurtosis Drift, Cardinality Drift - all in one pass, all exact (real
   numbers, not approximated), all derived by reusing dq_foundational_profiling's
   per-column stats rather than recomputing them. Deliberately calls
   dq_foundational_profiling itself (not the dq_dev_profile/dq_mon_profile
   tables from a prior DQ run) so this stays self-sufficient regardless of
   is_dq_req / order - same independence as every other drift technique.

   Requires (compiled first): dq_foundational_profiling.sas
   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_distribution_stats(dev=, mon=, out=);

    %dq_foundational_profiling(in_dataset=&dev, out=_dtd_devprof_);
    %dq_foundational_profiling(in_dataset=&mon, out=_dtd_monprof_);

    proc sql;
        create table _dtd_joined_ as
        select d.name,
               d.type,
               d.cardinality_count as dev_cardinality, m.cardinality_count as mon_cardinality,
               d.min as dev_min, m.min as mon_min,
               d.max as dev_max, m.max as mon_max,
               d.std as dev_std, m.std as mon_std,
               d.mean as dev_mean, m.mean as mon_mean,
               d.kurtosis as dev_kurtosis, m.kurtosis as mon_kurtosis,
               d.q25 as dev_q25, d.q50 as dev_q50, d.q75 as dev_q75,
               m.q25 as mon_q25, m.q50 as mon_q50, m.q75 as mon_q75
        from _dtd_devprof_ d
        inner join _dtd_monprof_ m on upcase(d.name) = upcase(m.name)
        where d.type = 1;   /* numeric columns only - these stats do not apply to char */
    quit;

    data &out;
        set _dtd_joined_;

        if dev_cardinality > 0 then
            cardinality_pct_change = round((mon_cardinality - dev_cardinality) / dev_cardinality, 0.001);

        if dev_std > 0 then
            std_drift_pct = round((mon_std - dev_std) / dev_std, 0.001);

        if dev_mean ne 0 then dev_cv = round(dev_std / dev_mean, 4);
        if mon_mean ne 0 then mon_cv = round(mon_std / mon_mean, 4);
        if dev_cv not in (., 0) then cv_drift_pct = round((mon_cv - dev_cv) / dev_cv, 0.001);

        kurtosis_delta = round(mon_kurtosis - dev_kurtosis, 4);

        if (dev_q75 - dev_q25) > 0 then
            median_shift_iqr = round((mon_q50 - dev_q50) / (dev_q75 - dev_q25), 4);

        drop type;
    run;

    proc datasets lib=work nolist;
        delete _dtd_devprof_ _dtd_monprof_ _dtd_joined_;
    quit;

%mend drift_distribution_stats;
