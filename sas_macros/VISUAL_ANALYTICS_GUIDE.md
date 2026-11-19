# Charts in SAS and SAS Visual Analytics

The Python project draws six figures (`utils/charts.py`). This guide shows how the SAS module reproduces
them in two ways, and how Visual Analytics (VA) reads the result from CAS.

| Python figure | What it shows | SAS chart (PROC SGPLOT) | VA object | Table |
|---|---|---|---|---|
| `segment_bubble_chart` | population % (x) vs Gini drop (y), size = exposure, colour = technique | `BUBBLE` | Bubble plot | `viz_bubble` |
| `segment_metric_heatmap` | segments x (PSI, delta Gini, delta KS, delta bad rate, root-cause score), colour = normalised severity | `HEATMAP` | Heat map | `viz_heatmap` |
| `sis_waterfall_chart` | SIS_Raw broken into its weighted components for one segment | `WATERFALL` | Waterfall chart | `viz_waterfall` |
| `segment_all_metrics_chart` / `segment_metric_time_series_chart` | one segment's metrics over the months, forecast point dashed | `TIMESERIES` | Line chart | `viz_timeseries` |
| `early_warning_urgency_chart` | segments projected to cross the alert level, fewest months first | `EARLY` | Bar chart (horizontal) | `viz_early_warning` |
| Streamlit `st.bar_chart` technique ranking | scores per technique | not ported as a macro | Bar chart on `seg_cross_top10` / `seg_combined` | existing tables |

## 1. The idea: SAS prepares, CAS holds, VA draws

```
segmentation run  -->  seg_viz_prepare / seg_viz_prepare_trend  -->  chart-ready tables (WORK)
                                      |                                  |
                                      |                                  +--> seg_viz_charts   (PROC SGPLOT, Results tab / PNG)
                                      +--> seg_viz_publish_cas --> CAS (promoted) --> Visual Analytics report
                                                                              +--> seg_viz_from_cas (read back + SGPLOT)
```

All calculation happens in SAS. The tables are "tidy" (one row per plotted mark), so VA needs no formulas
and the numbers in SAS and VA are identical.

## 2. The macros

| Macro | Role |
|---|---|
| `%seg_viz_prepare(seg=, out=viz)` | From any segment table (`<p>_<tech>_segments`, `<p>_cross_top10`, `<p>_summary`) builds `viz_bubble`, `viz_heatmap`, `viz_waterfall` (same formulas as `charts.py`). |
| `%seg_viz_prepare_trend(series=, periods=, forecast=, out=)` | From a trend run builds `viz_timeseries` (with gaps for months a segment was not among the worst N, plus the forecast point) and `viz_early_warning`. |
| `%seg_viz_charts(viz=, charts=)` | Draws the figures with PROC SGPLOT. |
| `%seg_viz_publish_cas(viz=, caslib=, tables=)` | Loads the tables into CAS and promotes them (and optionally saves `.sashdat`). |
| `%seg_viz_from_cas(viz=, caslib=)` | Reads the tables back from CAS and draws the charts. |

Run `seg_run_viz_viya.sas` section by section for a complete example.

### Table columns (what VA uses)

| Table | Grain | Columns |
|---|---|---|
| `viz_bubble` | segment | `seg_id`, `Technique`, `Segment_Label`, `Mon_Pct`, `Gini_Drop`, `Exposure`, `Bubble_Size` |
| `viz_heatmap` | segment x metric | `seg_id`, `Segment_Label`, `Metric`, `Metric_Order`, `Value`, `Value_Normalised`, `Value_Text` |
| `viz_waterfall` | segment x component | `seg_id`, `Segment_Label`, `Component`, `Order`, `Contribution`, `Base`, `End`, `Mid`, `Kind` (Component / Total), `Contribution_Text` |
| `viz_timeseries` | segment x period x metric | `Segment_No`, `Segment_Key`, `Technique`, `Segment_Definition`, `Period`, `Period_Index`, `Metric`, `Value` |
| `viz_early_warning` | flagged segment | `Rank`, `Label`, `Months_To_Breach`, `Confidence`, `Technique`, `Segment_Definition` |

## 3. Reading from CAS

A CAS table is read like any SAS table once a session and a libref exist:

```sas
cas mysess;                            /* start a session (SAS Studio often already has one) */
caslib _all_ assign;                   /* a libref for every caslib, e.g. CASUSER */
libname rca cas caslib="casuser";      /* or one libref for one caslib */

proc casutil incaslib="casuser"; list tables; quit;        /* what is in the caslib */

proc sgplot data=rca.viz_bubble;                           /* chart straight from the CAS table */
    bubble x=Mon_Pct y=Gini_Drop size=Exposure / group=Technique;
run;

data work.copy; set rca.viz_bubble; run;                   /* copy to WORK, then any procedure */
```

`%seg_viz_from_cas` does exactly this for all the chart tables. Tables must be **promoted** (global scope)
to be seen by other sessions and by VA; `%seg_viz_publish_cas` does that with `PROC CASUTIL ... PROMOTE`.

## 4. Building the Visual Analytics report

Open SAS Visual Analytics > **Explore and Visualize** or **Build Reports**, create a new report, then **Data > Add data**
and choose the caslib (for example `CASUSER` or a shared caslib) and the tables `viz_bubble`, `viz_heatmap`,
`viz_waterfall`, `viz_timeseries`, `viz_early_warning`.

**Page 1 - segment impact**
1. **Bubble plot** on `viz_bubble`: X axis = `Mon_Pct`, Y axis = `Gini_Drop`, Size = `Exposure`, Group (colour) = `Technique`,
   Data label = `Segment_Label`.
2. **Heat map** on `viz_heatmap`: X axis = `Metric` (sort by `Metric_Order`), Y axis = `Segment_Label` (sort by `seg_id`),
   Color = `Value_Normalised` (colour gradient green to red); show `Value_Text` as the cell label. A Crosstab with a
   display rule on `Value_Normalised` is an alternative.
3. **Waterfall chart** on `viz_waterfall`: Category = `Component` (sort by `Order`), Measure = `Contribution`; mark the
   `SIS_Raw` row as the total if your VA version offers it (otherwise a stacked bar using `Base` and `End` shows the same).
   Add a **filter** `Segment_Label` (a drop-down list control) so one segment is drawn, as Python draws segment 1.
4. **Interaction:** in the report's *Interactions / Filters* link the bubble plot to the waterfall and heat map so that
   clicking a bubble selects that segment everywhere (match on `Segment_Label`).

**Page 2 - trend (only after a trend run)**
5. **Line chart** on `viz_timeseries`: Category = `Period` (sort by `Period_Index`), Measure = `Value`, Group = `Metric`.
   Add a drop-down list control on `Segment_Key` (or `Segment_No`) so one segment is shown; month gaps stay empty.
   The forecast appears as the extra group `Root Cause Score (forecast)` (set a dashed line in the object's properties).
6. **Bar chart (horizontal)** on `viz_early_warning`: Category = `Label`, Measure = `Months_To_Breach`, Group = `Confidence`,
   sorted ascending by the measure (fewest months at the top).

Use *Display rules* for colours and thresholds; the numbers already carry the SAS definitions, so no calculated items
are needed.

## 5. Keeping it up to date

1. The SAS job (Cirrus API call, scheduled job, or the runner) runs the module and then `seg_viz_prepare*` and
   `seg_viz_publish_cas`.
2. The promoted tables are replaced under the same names (`droptable` then `load ... promote`), so the VA report
   shows the new data on refresh without being rebuilt.
3. Give report users read access to the caslib and the tables (caslib access controls in SAS Environment Manager).
4. Risk Modeling's own prepackaged VA reports read its reporting mart (`rm_rptmr`, for example `mm_measure_stats`
   for KPI values). The segment tables here are not in that mart, so they need their own report (this guide) or a
   load into a mart the report team agrees on.

## 6. Notes and limits

* The SAS code was written and checked statement by statement but has not been run on the server yet:
  expect to fix small syntax or option issues on the first run (send the log).
* PROC SGPLOT cannot hatch a bar by confidence as matplotlib does; the early-warning chart uses a darker and a lighter
  orange instead (the legend explains it).
* The waterfall uses the same fixed weights as the Python chart (0.25, 0.25, 0.20, 0.15, 0.15) - they are parameters
  of `seg_viz_prepare`.
* The technique-ranking bar charts of the Streamlit app are plain bar charts of existing tables
  (`seg_cross_top10`, `seg_combined`); build them in VA directly.
