/* ============================================================================
   drift_schema.sas
   (was %drift_tech1_schema in the old 20_drift_macros.sas)

   Added / dropped columns, dtype changes, dev vs mon.

   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_schema(dev=, mon=, out=);

    proc contents data=&dev out=_drift_devcols_(keep=name type length) noprint; run;
    proc contents data=&mon out=_drift_moncols_(keep=name type length) noprint; run;

    proc sql;
        create table &out as
        select coalesce(d.name, m.name) as name length=32,
               case
                   when d.name is null then "added"
                   when m.name is null then "dropped"
                   when d.type ne m.type or d.length ne m.length then "type_changed"
                   else "unchanged"
               end as change_type length=12,
               d.type as dev_type, m.type as mon_type,
               d.length as dev_length, m.length as mon_length
        from _drift_devcols_ d
        full join _drift_moncols_ m on upcase(d.name) = upcase(m.name);
    quit;

    proc datasets lib=work nolist;
        delete _drift_devcols_ _drift_moncols_;
    quit;

%mend drift_schema;
