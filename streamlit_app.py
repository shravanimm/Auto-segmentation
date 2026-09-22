import streamlit as st
import pandas as pd
from pathlib import Path

from models.config import (
    SlicerConfig,
    DLTConfig,
    GBConfig,
    KMeansConfig,
    FeatureBinningConfig,
    SchemaConfig,
    TrendAnalysisConfig,
)
from core.multi_period_analysis import (
    compute_trend_metrics,
    build_segment_time_series,
    forecast_segment_scores,
    reindex_segment_time_series,
)
from core.cross_technique_analysis import build_cross_technique_top10

from autoslicer_segmentation import run_autoslicer_segmentation
from kmeans_segmentation import run_kmeans_segmentation
from drift_localization_tree import run_drift_localization
from feature_binning_segmentation import run_feature_binning_segmentation
from gradient_boosting_segmentation import run_gradient_boosting_segmentation

from compare_segmentation_techniques import (
    benchmark_all_techniques,
    build_feature_schema,
    standardize_columns,
    DEV_FILE,
    MON_FILE,
    REQUESTED_FEATURES,
    DATA_DIR,
)

from llm.insight_generator import generate_insight, answer_data_question
from sas_macros.dq_drift_python_translation import main_wrapper
from tools.data_quality_tool import build_context as build_dq_context
from tools.data_drift_tool import build_context as build_drift_context
from tools.segment_analysis_tool import build_context as build_seg_context
from agents.model_rca_agent import answer as rca_answer
from utils.display_labels import (
    SECTION_LABELS as DRIFT_SECTION_LABELS,
    SECTION_EXPLANATIONS as DRIFT_SECTION_EXPLANATIONS,
    SECTION_GROUPS as DRIFT_SECTION_GROUPS,
    COLUMN_RENAME_MAP,
    SEGMENTATION_TOP10_COLUMNS,
)
from utils.charts import (
    segment_metric_heatmap,
    segment_bubble_chart,
    sis_waterfall_chart,
    segment_metric_time_series_chart,
    segment_all_metrics_chart,
    early_warning_urgency_chart,
)


# ============================================================
# Technique Parameter Registry
# ============================================================
#
# Approach 1 is fixed to development_data_5000_shap.csv /
# monitoring_data_5000_shap.csv. Every technique's search space is
# restricted (via build_feature_schema) to age/bureau_score/dti/
# utilization/region/employment_type. default_flag, pd_score, ead, shap_*,
# customer_id are never used as segmentation features -- only as
# metric/exposure inputs.
#
# "Decision Tree" is the user-facing label for the Gradient Boosting
# technique (a tree-ensemble implementation already in techniques/).

PARAM_SPECS = {
    "AutoSlicer": {
        "runner": run_autoslicer_segmentation,
        "config_cls": SlicerConfig,
        "rule_length_param": "max_combo_depth",
        "rule_length_default": 3,
        "rule_length_range": (1, 6),
        "percentile_param": "numeric_bins",
        "percentile_label": "Numeric Percentile Bins",
        "percentile_kind": "slider",
        "percentile_default": 4,
        "percentile_range": (2, 10),
        "auto_grid": {"max_combo_depth": [2, 3, 4], "beam_width": [10, 20, 30], "numeric_bins": [3, 4, 6]},
    },
    "Feature Binning": {
        "runner": run_feature_binning_segmentation,
        "config_cls": FeatureBinningConfig,
        "rule_length_param": None,
        "percentile_param": "max_bins",
        "percentile_label": "Bin Granularity (Max Bins)",
        "percentile_kind": "slider",
        "percentile_default": 8,
        "percentile_range": (3, 15),
        "auto_grid": {"max_bins": [5, 8, 10, 12], "min_bin_pct": [0.01, 0.02, 0.03]},
    },
    "Decision Tree": {
        "runner": run_gradient_boosting_segmentation,
        "config_cls": GBConfig,
        "rule_length_param": "max_depth",
        "rule_length_default": 3,
        "rule_length_range": (1, 6),
        "percentile_param": None,
        "auto_grid": {
            "max_depth": [2, 3, 4],
            "n_estimators": [50, 100, 150],
        },
    },
    "Clustering": {
        "runner": run_kmeans_segmentation,
        "config_cls": KMeansConfig,
        "rule_length_param": "max_tree_depth",
        "rule_length_default": 4,
        "rule_length_range": (1, 6),
        "percentile_param": None,
        "auto_grid": {"drift_weight": [0.2, 0.4, 0.6], "max_tree_depth": [3, 4, 5]},
    },
    "Drift Localization Tree": {
        "runner": run_drift_localization,
        "config_cls": DLTConfig,
        "rule_length_param": "max_depth",
        "rule_length_default": 3,
        "rule_length_range": (1, 6),
        "percentile_param": None,
        "auto_grid": {"max_depth": [2, 3, 4]},
    },
}


def build_config(tech, min_segment_size, ui_values, auto_optimize, dev_df, schema_cfg):
    """Translate user inputs into the technique's real Config dataclass."""
    spec = PARAM_SPECS[tech]
    kwargs = {"schema": schema_cfg, "min_abs_count": int(min_segment_size)}

    if tech == "Clustering":
        kwargs["min_cluster_pct"] = round(max(0.01, min_segment_size / len(dev_df)), 4)

    if tech == "Feature Binning":
        # FeatureBinningConfig has no min_abs_count field; its equivalent
        # minimum-segment-size gate is min_bin_pct (fraction of population).
        kwargs.pop("min_abs_count")
        kwargs["min_bin_pct"] = round(max(0.001, min_segment_size / len(dev_df)), 4)

    if auto_optimize:
        if spec["auto_grid"]:
            kwargs["param_grid"] = spec["auto_grid"]
    else:
        if spec["rule_length_param"]:
            kwargs[spec["rule_length_param"]] = ui_values["rule_length"]

        if spec["percentile_param"] == "drift_quantiles":
            values = ui_values.get("percentiles") or spec["percentile_default"]
            kwargs["drift_quantiles"] = tuple(sorted(values))
        elif spec["percentile_param"]:
            kwargs[spec["percentile_param"]] = ui_values["percentile_value"]

    return spec["config_cls"](**kwargs)


def render_technique_results(tech, result):
    st.subheader(f":material/summarize: Execution Summary — {tech}")

    overall = result.get("overall", {})
    for key, value in overall.items():
        st.write(f"**{key}** : {value}")

    if "execution_time" in result:
        st.write("**Execution Time** :", round(result["execution_time"], 2), "seconds")

    if result.get("selected_params"):
        st.write(
            f"**Auto-selected parameters** (best of {result.get('params_evaluated', '?')} "
            f"combinations, optimization score {result.get('optimization_score', 0):.4f}):"
        )
        st.json(result["selected_params"])

    segments_df = result.get("segments", pd.DataFrame())

    st.subheader(f":material/list_alt: Top Segments — {tech}")
    st.dataframe(segments_df, use_container_width=True)

    if not segments_df.empty:
        st.download_button(
            label=":material/download: Download Results CSV",
            data=segments_df.to_csv(index=False),
            file_name=f"{tech.replace(' ', '_')}_results.csv",
            mime="text/csv",
            key=f"download_{tech}",
        )

        chart_df = standardize_columns(segments_df.copy(), tech)

        st.subheader(f":material/thermostat: Segment x Metric Heatmap — {tech}")
        fig = segment_metric_heatmap(chart_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(f":material/bubble_chart: Bubble Chart — {tech}")
        fig = segment_bubble_chart(chart_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(f":material/water_drop: SIS Waterfall — {tech} (Top Segment)")
        fig = sis_waterfall_chart(chart_df.iloc[0])
        if fig is not None:
            st.pyplot(fig)

        try:
            top_segment = segments_df.iloc[0]

            segment_info = {
                "Segment_Definition": str(
                    top_segment.get("Segment_Definition", top_segment.get("segment", "Unknown Segment"))
                ),
                "PSI": float(top_segment.get("PSI", top_segment.get("psi", 0))),
                "Delta_Gini": float(top_segment.get("Delta_Gini", top_segment.get("delta_gini", 0))),
                "Delta_BR": float(top_segment.get("Delta_BR", 0)),
                "Root_Cause_Feature": str(top_segment.get("Root_Cause_Feature", "Not Available")),
                "Severity_Score": float(
                    top_segment.get("Severity_Score", top_segment.get("final_score", 0))
                ),
                "Business_Impact_Score": float(top_segment.get("Business_Impact_Score", 0)),
            }

            with st.spinner("Generating AI Executive Summary..."):
                llm_summary = generate_insight(segment_info)

            st.subheader(f":material/smart_toy: AI Generated Executive Summary — {tech}")
            st.markdown(llm_summary)

        except Exception as e:
            st.warning(f"Could not generate LLM summary: {e}")


def _auto_detect_schema(dev_df: pd.DataFrame) -> SchemaConfig:
    """Fully automatic SchemaConfig for an arbitrary dev dataset -- numeric/
    categorical/target/score/id/time all inferred from the data by
    utils.schema_detection.detect_schema, so a completely different dataset
    (new columns, different names) is picked up automatically with no code
    change needed here. Used by both Tab 1 (user-uploaded datasets) and
    Tab 2's trend-analysis path (user-selected monthly files).

    Two manual overrides on top of the generic detection, both found by
    testing against the real v2_1M data -- both are no-ops for datasets
    without these exact columns:

    - weight_col is pinned to "ead" when present. detect_schema's
      weight/exposure pattern matches any column *containing* "amount" --
      v2_1M's sanctioned_amount column matches it and, because it sits
      earlier in the column order than ead, wins the auto-detection,
      silently using the wrong exposure basis for every EAD-weighted
      metric (Business_Impact_Score, Mon_Exposure_Pct, etc.).
    - lgd_actual (loss given default) is excluded even though its name
      matches no target/score pattern -- it's a model-output field in the
      same leakage category as target/score, just not named obviously
      enough for the generic detector to catch on its own.
    """
    from utils.schema_detection import detect_schema

    cols = set(dev_df.columns)
    seed_cfg = SchemaConfig(weight_col="ead") if "ead" in cols else SchemaConfig()
    detected = detect_schema(dev_df, seed_cfg)

    exclude_cols = list(detected["excluded_cols"])
    numeric_cols = list(detected["numeric_cols"])
    categorical_cols = list(detected["categorical_cols"])
    if "lgd_actual" in cols and "lgd_actual" not in exclude_cols:
        exclude_cols.append("lgd_actual")
        numeric_cols = [c for c in numeric_cols if c != "lgd_actual"]
        categorical_cols = [c for c in categorical_cols if c != "lgd_actual"]

    return SchemaConfig(
        target_col=detected["target_col"],
        score_col=detected["score_col"],
        weight_col=detected["weight_col"],
        id_cols=detected["id_cols"],
        exclude_cols=exclude_cols,
        numeric_cols=numeric_cols,
        categorical_cols=categorical_cols,
    )


# ============================================================
# Page Config
# ============================================================

st.set_page_config(
    page_title="Model RCA Studio",
    page_icon="🧭",
    layout="wide"
)

st.markdown(
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');

    /* Cascades to markdown/headers/captions/dataframes naturally via
       inheritance. Deliberately NOT !important and NOT targeting bare
       span/div/p -- Streamlit's Material-icon glyphs render as unlabeled
       <span> elements keyed off font-family: "Material Symbols Rounded",
       and an important/broad override here defeats that font and makes
       icons fall back to showing their literal ligature text. */
    html, body, .stApp {
        font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    }

    /* Native form-control tags don't inherit font-family from ancestors by
       browser default, so they need it restated -- but only on the tag
       itself, not on icon spans nested inside it. */
    button, input, select, textarea {
        font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    }

    html { font-size: 18px; }

    .block-container { padding-top: 1.5rem; padding-bottom: 3rem; padding-left: 3rem; padding-right: 3rem; max-width: 100%; }

    /* ---- Hero header ---- */
    .app-header-wrap {
        text-align: center;
        padding: 2rem 1rem 1.5rem 1rem;
        background: linear-gradient(180deg, #EAF1F8 0%, rgba(234,241,248,0) 100%);
        border-radius: 14px;
        margin-bottom: 1.5rem;
    }
    .app-header-title {
        font-size: 2.75rem;
        font-weight: 800;
        letter-spacing: -0.02em;
        color: #1B4F72;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 0.65rem;
        margin: 0;
    }
    .app-header-title svg { flex-shrink: 0; }
    .app-header-subtitle {
        font-size: 1.2rem;
        font-weight: 500;
        color: #5A6570;
        margin-top: 0.5rem;
    }
    .app-header-divider {
        height: 4px;
        width: 96px;
        background: linear-gradient(90deg, #1B4F72, #2E86C1);
        margin: 1.1rem auto 0 auto;
        border-radius: 2px;
    }

    /* ---- Tabs ----
       This Streamlit version renders tabs as [role="tablist"] >
       [data-testid="stTab"], not the older data-baseweb markup -- verified
       directly against the live DOM before writing these selectors. */
    .stTabs [role="tablist"] {
        gap: 8px;
        justify-content: center;
        border-bottom: 1px solid #E3E8ED;
    }
    .stTabs [data-testid="stTab"] {
        padding: 0.85rem 1.4rem;
    }
    .stTabs [data-testid="stTab"] p {
        font-weight: 700 !important;
        font-size: 1.25rem !important;
    }
    .stTabs [data-testid="stTab"][aria-selected="true"] p,
    .stTabs [data-testid="stTab"][aria-selected="true"] span {
        color: #1B4F72 !important;
    }

    /* ---- Headings & widgets ---- */
    h1, h2, h3 { font-weight: 700 !important; letter-spacing: -0.01em; }
    .stButton button { border-radius: 8px; font-weight: 600; font-size: 1rem; padding: 0.5rem 1.25rem; }
    .stButton button[kind="primary"] { background-color: #1B4F72; border-color: #1B4F72; }
    .stCheckbox label p, .stRadio label p { font-size: 1rem !important; }
    .stCaption, [data-testid="stCaptionContainer"] p { font-size: 0.95rem !important; }
    [data-testid="stMetricValue"] { font-weight: 700; color: #1B4F72; }
    </style>
    """,
    unsafe_allow_html=True,
)

_COMPASS_SVG = """
<svg width="46" height="46" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
  <circle cx="24" cy="24" r="21" stroke="#1B4F72" stroke-width="3" fill="#EAF1F8"/>
  <path d="M31 17 L20 20 L17 31 L28 28 Z" fill="#2E86C1" stroke="#1B4F72" stroke-width="1.5" stroke-linejoin="round"/>
  <circle cx="24" cy="24" r="2.4" fill="#1B4F72"/>
</svg>
"""

st.markdown(
    f"""
    <div class="app-header-wrap">
        <div class="app-header-title">{_COMPASS_SVG}Model RCA Studio</div>
        <div class="app-header-subtitle">Data Quality, Drift Detection &amp; Root-Cause Segmentation for Model Monitoring</div>
        <div class="app-header-divider"></div>
    </div>
    """,
    unsafe_allow_html=True,
)


# ============================================================
# Tabs
# ============================================================

tab_home, tab1, tab2, tab3 = st.tabs(
    [
        ":material/home: Home",
        ":material/scatter_plot: Segmentation Analysis",
        ":material/leaderboard: Technique Comparison",
        ":material/insights: Cross-Technique Insights",
    ]
)

# ============================================================
# TAB 1
# ============================================================

with tab1:

    st.header(":material/scatter_plot: Segmentation Analysis")

    uploaded_dev = st.file_uploader(
        "Development Dataset (CSV) — optional, uses the built-in demo dataset if empty",
        type=["csv"],
        key="tab1_dev_upload",
    )
    uploaded_mon = st.file_uploader(
        "Monitoring Dataset (CSV) — optional, uses the built-in demo dataset if empty",
        type=["csv"],
        key="tab1_mon_upload",
    )

    using_custom_dataset = uploaded_dev is not None and uploaded_mon is not None

    if uploaded_dev is not None and uploaded_mon is None:
        st.info("Upload a monitoring dataset too to use a custom dataset — falling back to the demo dataset.")
    elif uploaded_mon is not None and uploaded_dev is None:
        st.info("Upload a development dataset too to use a custom dataset — falling back to the demo dataset.")

    if using_custom_dataset:
        dev_df = pd.read_csv(uploaded_dev)
        mon_df = pd.read_csv(uploaded_mon)
        try:
            schema_cfg = _auto_detect_schema(dev_df)
        except ValueError as e:
            st.error(f"Could not auto-detect a schema for the uploaded dataset: {e}")
            st.stop()

        feature_cols = sorted((schema_cfg.numeric_cols or []) + (schema_cfg.categorical_cols or []))
        st.caption(
            f"Development: `{uploaded_dev.name}` ({len(dev_df):,} rows) · "
            f"Monitoring: `{uploaded_mon.name}` ({len(mon_df):,} rows). "
            f"Auto-detected target: **{schema_cfg.target_col}**, score: **{schema_cfg.score_col}**, "
            f"weight/exposure: **{schema_cfg.weight_col or 'none'}**. "
            f"Segmentation features: **{', '.join(feature_cols) if feature_cols else 'none detected'}**. "
            f"Target, score, weight, ID, time and SHAP columns are excluded from segment rule "
            "discovery for every technique below — they are only used to compute performance, "
            "drift and exposure metrics."
        )
    else:
        dev_df = pd.read_csv(DEV_FILE)
        mon_df = pd.read_csv(MON_FILE)
        schema_cfg = build_feature_schema(dev_df)

        st.caption(
            f"Development: `{Path(DEV_FILE).name}` ({len(dev_df):,} rows) · "
            f"Monitoring: `{Path(MON_FILE).name}` ({len(mon_df):,} rows). "
            f"Segmentation features: **{', '.join(REQUESTED_FEATURES)}**. "
            "`default_flag`, `pd_score`, `ead`, `shap_*` and `customer_id` are excluded from "
            "segment rule discovery for every technique below — they are only used "
            "to compute performance, drift and exposure metrics."
        )

    selected_techniques = st.multiselect(
        "1. Segmentation Technique(s)",
        list(PARAM_SPECS.keys()),
        default=["AutoSlicer"],
    )

    min_segment_size = st.number_input(
        "2. Minimum Segment Size (rows)",
        min_value=10,
        max_value=int(len(dev_df)),
        value=min(150, int(len(dev_df))),
        step=10,
        help="Candidate segments with fewer development-period rows than this "
             "are discarded, regardless of technique.",
    )

    auto_optimize = st.checkbox(
        "Auto-generate optimal values for Max Rule Length / Percentiles",
        value=False,
        help="Runs a grid search (core.parameter_optimization) over each "
             "technique's search-space parameters and keeps the combination "
             "with the highest aggregate Business Impact Score, instead of "
             "using the manual values set below.",
    )

    ui_values = {}

    for technique in selected_techniques:
        spec = PARAM_SPECS[technique]
        with st.expander(f"{technique} Parameters", expanded=True):
            values = {}

            if technique == "Drift Localization Tree":
                st.caption(
                    "Uses the same underlying idea as Decision Tree — trains a model to tell "
                    "development rows apart from monitoring rows, then reads off where it "
                    "succeeds — but as a single tree instead of an ensemble, so it's faster "
                    "and coarser (fewer, larger candidate segments), not a different method."
                )

            if auto_optimize:
                st.info("Max Rule Length / Percentiles will be auto-selected via grid search.")
            else:
                if spec["rule_length_param"]:
                    lo, hi = spec["rule_length_range"]
                    values["rule_length"] = st.slider(
                        "Max Rule Length",
                        min_value=lo,
                        max_value=hi,
                        value=spec["rule_length_default"],
                        key=f"rule_{technique}",
                    )
                else:
                    st.caption("Max Rule Length — not applicable (single-feature segments only).")

                if spec["percentile_param"] == "drift_quantiles":
                    values["percentiles"] = st.multiselect(
                        spec["percentile_label"],
                        spec["percentile_options"],
                        default=spec["percentile_default"],
                        key=f"perc_{technique}",
                    )
                elif spec["percentile_param"]:
                    lo, hi = spec["percentile_range"]
                    values["percentile_value"] = st.slider(
                        spec["percentile_label"],
                        min_value=lo,
                        max_value=hi,
                        value=spec["percentile_default"],
                        key=f"perc_{technique}",
                    )
                else:
                    st.caption("Percentiles — not applicable for this technique.")

            ui_values[technique] = values

    if st.button("Run Segment Analysis"):

        if not selected_techniques:
            st.error("Select at least one segmentation technique.")
            st.stop()

        for technique in selected_techniques:
            spec = PARAM_SPECS[technique]

            cfg = build_config(
                technique,
                min_segment_size,
                ui_values.get(technique, {}),
                auto_optimize,
                dev_df,
                schema_cfg,
            )

            with st.spinner(f"Running {technique}..."):
                result = spec["runner"](dev_df, mon_df, cfg=cfg)

            st.success(f"{technique} Completed Successfully")

            render_technique_results(technique, result)

            st.divider()


# ============================================================
# TAB 2
# ============================================================

def _build_qa_context() -> str:
    """Compact text summary of whatever run results are currently in
    session_state -- classic and/or trend, whichever the user last ran --
    for the free-form Q&A assistant. Kept small (top rows only) to stay
    within a reasonable prompt size."""
    parts = []

    summary_df = st.session_state.get("summary_df", pd.DataFrame())
    if not summary_df.empty:
        cols = [c for c in ["Technique", "Overall_Score_100", "Max_PSI", "Max_Gini_Drop",
                             "Root_Cause_Feature", "Root_Cause_Score"] if c in summary_df.columns]
        parts.append("=== Technique Comparison (classic run) ===\n" + summary_df[cols].to_string(index=False))

    cross_top10_df = st.session_state.get("cross_top10_df", pd.DataFrame())
    if not cross_top10_df.empty:
        cols = [c for c in ["Overall_Rank", "Technique", "Segment_Definition",
                             "Normalized_Root_Cause_Score"] if c in cross_top10_df.columns]
        parts.append("=== Cross-Technique Top 10 (classic run) ===\n" + cross_top10_df[cols].to_string(index=False))

    trend_df = st.session_state.get("trend_df", pd.DataFrame())
    if not trend_df.empty:
        cols = [c for c in ["Technique", "Segment_Definition", "Periods_Appeared", "Total_Periods",
                             "Frequency", "Consistency_Score", "Trend_Impact_Score",
                             "Severity_Score_Trend"] if c in trend_df.columns]
        top = trend_df.nlargest(15, "Severity_Score_Trend")[cols]
        parts.append("=== Trend Analysis Summary (top 15 by Severity_Score_Trend) ===\n" + top.to_string(index=False))

    trend_cross_top10_df = st.session_state.get("trend_cross_top10_df", pd.DataFrame())
    if not trend_cross_top10_df.empty:
        cols = [c for c in ["Overall_Rank", "Technique", "Segment_Definition",
                             "Normalized_Root_Cause_Score"] if c in trend_cross_top10_df.columns]
        parts.append("=== Cross-Technique Trend Top 10 ===\n" + trend_cross_top10_df[cols].to_string(index=False))

    time_series_df = st.session_state.get("trend_time_series_df", pd.DataFrame())
    if not time_series_df.empty:
        forecast_df = forecast_segment_scores(time_series_df, TrendAnalysisConfig())
        if not forecast_df.empty:
            parts.append("=== Early Warning Forecast ===\n" + forecast_df.to_string(index=False))

    return "\n\n".join(parts) if parts else ""


with tab2:

    st.header(":material/leaderboard: Compare All Segmentation Techniques")

    trend_enabled = st.radio(
        "Run Trend Analysis (multiple monitoring months)?",
        options=["No", "Yes"],
        horizontal=True,
        index=0,
        key="trend_analysis_toggle",
        help="No (default): today's single dev-vs-monitoring comparison, unchanged. "
             "Yes: supply 1 development file + several monitoring files (one per month) "
             "to additionally see which segments recur as worst performers over time.",
    ) == "Yes"

    if trend_enabled:

        csv_files = sorted(p.name for p in DATA_DIR.glob("*.csv"))
        dev_like = [f for f in csv_files if "dev" in f.lower()]
        mon_like = [f for f in csv_files if "mon" in f.lower()]
        v2_mon_defaults = sorted(f for f in mon_like if f.lower().startswith("v2_monitoring"))

        trend_dev_file = st.selectbox(
            "Development dataset",
            options=dev_like or csv_files,
            index=(dev_like or csv_files).index("v2_development_data.csv")
            if "v2_development_data.csv" in (dev_like or csv_files) else 0,
        )
        trend_mon_files = st.multiselect(
            "Monitoring datasets, in chronological order (one per month)",
            options=mon_like or csv_files,
            default=v2_mon_defaults,
        )

        run_trend_clicked = st.button("Run Trend Analysis", disabled=len(trend_mon_files) < 2)
        if len(trend_mon_files) == 1:
            st.caption("Pick at least 2 monitoring months to compute recurrence trends.")

        if run_trend_clicked:
            dev_df = pd.read_csv(DATA_DIR / trend_dev_file)
            trend_schema = _auto_detect_schema(dev_df)

            period_results = {}
            progress = st.progress(0.0, text="Starting trend analysis...")
            for i, mon_file in enumerate(trend_mon_files):
                progress.progress(
                    i / len(trend_mon_files),
                    text=f"Running all 5 techniques for {mon_file} ({i + 1}/{len(trend_mon_files)})...",
                )
                mon_df = pd.read_csv(DATA_DIR / mon_file)
                _, combined_segments_df, _, _ = benchmark_all_techniques(
                    dev_df=dev_df, mon_df=mon_df, save_outputs=False, schema_cfg=trend_schema,
                )
                period_results[mon_file] = combined_segments_df
            progress.progress(1.0, text="Computing trend metrics...")

            trend_df = compute_trend_metrics(period_results, TrendAnalysisConfig())
            progress.empty()

            # Everything below is *display*, which must not live inside this
            # `if run_trend_clicked:` block: st.button() only returns True on
            # the exact rerun where it was clicked, so on the very next
            # rerun (e.g. the user touching the segment picker below) it
            # reverts to False and this whole block would be skipped --
            # making the summary table disappear. Storing results in
            # session_state and rendering them separately (same pattern
            # Tab 3 already uses for cross_top10_df) keeps them visible
            # across unrelated widget interactions.
            st.session_state["trend_df"] = trend_df
            st.session_state["trend_months_count"] = len(trend_mon_files)
            st.session_state["trend_periods"] = list(period_results.keys())

            # Symmetric to the classic path: a fresh trend run makes any
            # earlier classic-benchmark results stale -- clear them so
            # Tab 3 doesn't keep showing a leftover classic section (with
            # its own duplicate heatmap/bubble/waterfall) alongside this
            # trend run.
            st.session_state["cross_top10_df"] = pd.DataFrame()
            st.session_state["cross_exec_summary_df"] = pd.DataFrame()
            st.session_state["summary_df"] = pd.DataFrame()

            if trend_df.empty:
                st.session_state["trend_cross_top10_df"] = pd.DataFrame()
                st.session_state["trend_time_series_df"] = pd.DataFrame()
            else:
                # Cross-technique step (taskflow step 4, trend version): pool
                # each technique's worst trend segments and normalize
                # Root_Cause_Score_Trend across all of them, same as the
                # classic cross-technique top-10 but on trend-boosted scores.
                # build_cross_technique_top10 looks for columns literally
                # named Severity_Score/Root_Cause_Score, so the trend-boosted
                # values are substituted in on a copy before calling it.
                trend_for_cross = trend_df.copy()
                trend_for_cross["Severity_Score"] = trend_for_cross["Severity_Score_Trend"]
                trend_for_cross["Root_Cause_Score"] = trend_for_cross["Root_Cause_Score_Trend"]
                st.session_state["trend_cross_top10_df"] = build_cross_technique_top10(trend_for_cross)

                # Add-on requested by the manager: the raw month-by-month
                # metrics (not just the trend-boosted summary), for whichever
                # segment the user wants to inspect.
                st.session_state["trend_time_series_df"] = build_segment_time_series(
                    period_results, TrendAnalysisConfig()
                )

        # ====================================================
        # Display (reads from session_state, not run_trend_clicked, so it
        # survives reruns triggered by widgets below it -- e.g. the segment
        # picker further down).
        # ====================================================

        trend_df = st.session_state.get("trend_df", pd.DataFrame())
        time_series_df = st.session_state.get("trend_time_series_df", pd.DataFrame())
        forecast_df = forecast_segment_scores(time_series_df, TrendAnalysisConfig()) if not time_series_df.empty else pd.DataFrame()

        if trend_df.empty:
            if run_trend_clicked:
                st.warning("No segments to report -- check that the selected files produced valid candidates.")
        else:
            st.success(
                f"Trend Analysis Completed Successfully "
                f"({st.session_state.get('trend_months_count', '?')} months, {trend_df['Technique'].nunique()} techniques)"
            )

            st.subheader(":material/trending_up: Trend Analysis Summary")
            st.caption(
                "One row per segment matched across the selected months (by rule text) within its "
                "own technique. Frequency = share of months it ranked in that technique's worst-10. "
                "Recency_Factor = how recently it last appeared (1.0 = most recent month). "
                "Consistency_Score = longest unbroken streak of months it appeared in, divided by "
                "total months -- a segment that appears then disappears then reappears scores lower "
                "here than one that stayed continuously present, even at the same overall frequency. "
                "Trend_Impact_Score blends the three; SIS_Trend/Root_Cause_Score_Trend/"
                "Severity_Score_Trend are the existing formulas with SIS boosted by that trend score."
            )

            display_cols = [
                "Technique", "Segment_Definition", "Periods_Appeared", "Total_Periods",
                "Appeared_In", "Frequency", "Recency_Factor", "Consistency_Score",
                "Trend_Impact_Score", "SIS_Raw", "SIS_Trend", "Root_Cause_Score_Trend",
                "Severity_Score_Trend",
            ]
            st.dataframe(trend_df[display_cols], use_container_width=True)
            st.download_button(
                label=":material/download: Download Trend Analysis CSV",
                data=trend_df.to_csv(index=False),
                file_name="trend_analysis_summary.csv",
                mime="text/csv",
                key="download_trend_analysis",
            )

            # ====================================================
            # Segment-level Analysis (renamed from "Metric Time Series") --
            # placed directly below the Trend Analysis Summary CSV per
            # manager feedback, ahead of the charts below.
            # ====================================================

            if not time_series_df.empty:
                st.subheader(":material/query_stats: Segment-level Analysis")
                st.caption(
                    "Add-on to the summary table above (unchanged) -- pick one segment to see its "
                    "actual month-by-month numbers (population %, exposure, AUC, KS, bad rate, SIS, "
                    "DIS, SHAP shift, Root_Cause_Score) across *every* month analyzed, not just the "
                    "single trend-boosted score. Months where the segment didn't rank in that "
                    "technique's worst-10 show as a blank row / a gap in the line -- not skipped or "
                    "interpolated -- so the recurrence pattern (continuous vs. on-and-off) is visible "
                    "at a glance. The downloadable CSV includes every column shown here."
                )

                segment_options = (
                    time_series_df[["Technique", "Segment_Definition"]]
                    .drop_duplicates()
                    .apply(lambda r: f"{r['Technique']} — {r['Segment_Definition']}", axis=1)
                    .tolist()
                )
                selected = st.selectbox(
                    "Select a segment to view its time series",
                    options=["-- Select a segment --"] + sorted(segment_options),
                    index=0,
                    key="time_series_segment_picker",
                )

                if selected != "-- Select a segment --":
                    sel_tech, sel_seg = selected.split(" — ", 1)
                    seg_ts = time_series_df[
                        (time_series_df["Technique"] == sel_tech)
                        & (time_series_df["Segment_Definition"] == sel_seg)
                    ].sort_values("Period_Index")

                    all_periods = st.session_state.get("trend_periods", [])
                    seg_ts_full = reindex_segment_time_series(seg_ts, all_periods) if all_periods else seg_ts

                    display_ts = seg_ts_full.drop(columns=["Period_Index"], errors="ignore").copy()
                    if "Root_Cause_Score" in display_ts.columns:
                        display_ts.insert(
                            1, "Appeared_This_Month",
                            display_ts["Root_Cause_Score"].notna().map({True: "✓", False: "—"}),
                        )
                    st.dataframe(display_ts, use_container_width=True)

                    forecast_point = None
                    if not forecast_df.empty:
                        match = forecast_df[
                            (forecast_df["Technique"] == sel_tech)
                            & (forecast_df["Segment_Definition"] == sel_seg)
                        ]
                        if not match.empty:
                            forecast_point = float(match.iloc[0]["Predicted_Next_Root_Cause_Score"])

                    st.markdown("**All key metrics together, full month range:**")
                    fig = segment_all_metrics_chart(seg_ts_full, sel_seg)
                    if fig is not None:
                        st.pyplot(fig)
                    else:
                        st.info("Not enough numeric data across the selected months to plot this segment.")

                    col1, col2 = st.columns(2)
                    with col1:
                        fig = segment_metric_time_series_chart(seg_ts_full, "Root_Cause_Score", sel_seg, forecast_point=forecast_point)
                        if fig is not None:
                            st.pyplot(fig)
                    with col2:
                        fig = segment_metric_time_series_chart(seg_ts_full, "Mon_AUC", sel_seg)
                        if fig is not None:
                            st.pyplot(fig)

                st.download_button(
                    label=":material/download: Download Full Time-Series CSV (all segments)",
                    data=time_series_df.to_csv(index=False),
                    file_name="trend_metric_time_series.csv",
                    mime="text/csv",
                    key="download_trend_time_series",
                )

            trend_top10 = trend_df.nlargest(10, "Severity_Score_Trend")

            st.subheader(":material/thermostat: Segment x Metric Heatmap (Top 10 by Severity_Score_Trend)")
            fig = segment_metric_heatmap(trend_top10)
            if fig is not None:
                st.pyplot(fig)

            st.subheader(":material/bubble_chart: Bubble Chart — Population vs Gini Drop (size = exposure)")
            fig = segment_bubble_chart(trend_top10)
            if fig is not None:
                st.pyplot(fig)

            st.subheader(":material/water_drop: SIS Waterfall — #1 Most Persistent Root Cause")
            fig = sis_waterfall_chart(trend_top10.iloc[0])
            if fig is not None:
                st.pyplot(fig)

            st.subheader(":material/military_tech: Most Persistent Root Causes (Top 5 by Severity_Score_Trend)")
            top5 = trend_df.nlargest(5, "Severity_Score_Trend")
            for _, r in top5.iterrows():
                st.write(
                    f"**{r['Technique']}** — {r['Segment_Definition']}  \n"
                    f"Appeared in {r['Periods_Appeared']}/{r['Total_Periods']} months "
                    f"({r['Appeared_In']}) · Trend Impact Score {r['Trend_Impact_Score']:.2f} · "
                    f"Severity_Score_Trend {r['Severity_Score_Trend']:.2f}"
                )

        # ====================================================
        # Early Warning (new feature): plain linear extrapolation of each
        # segment's Root_Cause_Score, flagging ones on track to cross the
        # alert threshold soon. Pure math on already-computed
        # trend_time_series_df -- no new pipeline runs.
        # ====================================================

        if not forecast_df.empty:
            st.subheader(":material/auto_awesome: Early Warning: Segments Projected to Worsen")
            _cfg = TrendAnalysisConfig()
            st.caption(
                f"Ordinary least-squares linear regression (scipy.stats.linregress) of each "
                f"segment's Root_Cause_Score against the months it appeared, projected one period "
                f"forward. Wherever there's enough history (3+ months), the R² (goodness of fit), "
                f"the trend's p-value (is the slope statistically distinguishable from zero), and a "
                f"95% prediction interval on the forecast are reported alongside the point estimate. "
                f"With exactly 2 months, the line is still fitted, but there's no residual data left "
                f"to test significance or bound the forecast, so those fields are left blank rather "
                f"than implied -- shown as \"Low (2 points)\" confidence. Flagged when the trend is "
                f"worsening (positive slope) and projected to cross {_cfg.forecast_alert_threshold} "
                f"within {_cfg.forecast_horizon_months} months. Threshold/horizon are tunable "
                f"defaults, not a validated cutoff."
            )
            n_flagged = int(forecast_df["Early_Warning"].sum())
            if n_flagged:
                st.warning(f"⚠️ {n_flagged} segment(s) projected to breach the threshold within the forecast horizon.")

                st.markdown("**Segments to Watch (most urgent first):**")
                watch_list = forecast_df[forecast_df["Early_Warning"]].sort_values("Months_To_Breach").head(5)
                for r in watch_list.itertuples():
                    ci_part = (
                        f" (95% CI: {r.Predicted_Next_Lower95:.2f}–{r.Predicted_Next_Upper95:.2f})"
                        if r.Predicted_Next_Lower95 is not None else ""
                    )
                    stats_part = (
                        f" · R²={r.R_Squared:.2f}, p={r.Trend_P_Value:.3f}"
                        if r.R_Squared is not None else ""
                    )
                    st.write(
                        f"**{r.Technique}** — {r.Segment_Definition}  \n"
                        f"Currently at {r.Current_Root_Cause_Score:.2f}, projected to reach "
                        f"{r.Predicted_Next_Root_Cause_Score:.2f}{ci_part} next month · last seen in "
                        f"*{r.Last_Appeared_Period}* · expected to cross the alert threshold in "
                        f"~{r.Months_To_Breach} month(s){stats_part} · {r.Confidence.lower()}"
                    )

                fig = early_warning_urgency_chart(forecast_df)
                if fig is not None:
                    st.pyplot(fig)
            else:
                st.info("No segments currently projected to breach the threshold within the forecast horizon.")

            show_only_flagged = st.checkbox(
                "Show only flagged (Early_Warning) segments in the table below",
                value=n_flagged > 0,
                key="early_warning_only_flagged",
            )
            table_df = forecast_df[forecast_df["Early_Warning"]] if show_only_flagged and n_flagged else forecast_df
            st.dataframe(table_df, use_container_width=True)

    elif st.button("Run Benchmark"):

        with st.spinner(
            "Running all segmentation techniques..."
        ):

            summary_df, combined_segments_df, cross_top10_df, cross_exec_summary_df = (
                benchmark_all_techniques()
            )

        st.session_state["cross_top10_df"] = cross_top10_df
        st.session_state["cross_exec_summary_df"] = cross_exec_summary_df
        st.session_state["summary_df"] = summary_df

        # A classic run makes any earlier trend-analysis results stale --
        # clear them so Tab 3 doesn't keep showing a leftover trend section
        # (with its own duplicate heatmap/bubble/waterfall) from a run that
        # may be from a totally different dataset or parameters.
        st.session_state["trend_df"] = pd.DataFrame()
        st.session_state["trend_cross_top10_df"] = pd.DataFrame()
        st.session_state["trend_time_series_df"] = pd.DataFrame()
        st.session_state["trend_months_count"] = None
        st.session_state["trend_periods"] = []

        st.success(
            "Benchmark Completed Successfully"
        )

        # ====================================================
        # Sort By Overall Score
        # ====================================================

        ranking_df = (
            summary_df
            .sort_values(
                by="Overall_Score_100",
                ascending=False
            )
            .reset_index(drop=True)
        )

        ranking_df["Rank"] = (
            ranking_df.index + 1
        )

        ranking_df = ranking_df[
            ["Rank"] +
            [c for c in ranking_df.columns if c != "Rank"]
        ]

        # ====================================================
        # Ranking Table
        # ====================================================

        st.subheader(
            ":material/bar_chart: Technique Ranking"
        )

        st.dataframe(
            ranking_df,
            use_container_width=True
        )

        # ====================================================
        # Top 10 Per Technique (5 x 10 = 50 rows)
        # ====================================================

        st.subheader(":material/list_alt: Top 10 Segments per Technique")
        st.caption(
            "Full metric set, same columns as Cross-Technique Insights (Tab 3). "
            "A technique shows fewer than 10 rows only if it did not discover "
            "that many candidates passing the significance/support gates -- "
            "counts are not padded to 10."
        )

        if not combined_segments_df.empty:
            _rank_col = (
                "Severity_Score" if "Severity_Score" in combined_segments_df.columns
                else "Business_Impact_Score"
            )
            groups = []
            for _, g in combined_segments_df.groupby("Technique"):
                top = g.nlargest(10, _rank_col).reset_index(drop=True)
                top.insert(1, "Rank_Within_Technique", top.index + 1)
                groups.append(top)
            top10_per_technique = pd.concat(groups, ignore_index=True)

            st.dataframe(top10_per_technique, use_container_width=True)
            st.download_button(
                label=":material/download: Download Top 10 x 5 CSV",
                data=top10_per_technique.to_csv(index=False),
                file_name="top10_per_technique.csv",
                mime="text/csv",
                key="download_top10_per_technique",
            )

        # ====================================================
        # Overall Score Chart
        # ====================================================

        if "Overall_Score_100" in ranking_df.columns:

            st.subheader(
                ":material/military_tech: Overall Score Comparison"
            )

            st.bar_chart(
                ranking_df.set_index(
                    "Technique"
                )["Overall_Score_100"]
            )

        # ====================================================
        # PSI Chart
        # ====================================================

        if "Max_PSI" in ranking_df.columns:

            st.subheader(
                ":material/trending_up: PSI Comparison"
            )

            st.bar_chart(
                ranking_df.set_index(
                    "Technique"
                )["Max_PSI"]
            )

        # ====================================================
        # Runtime Chart
        # ====================================================

        if "Execution_Time_Sec" in ranking_df.columns:

            st.subheader(
                ":material/timer: Runtime Comparison"
            )

            st.bar_chart(
                ranking_df.set_index(
                    "Technique"
                )["Execution_Time_Sec"]
            )

        # ====================================================
        # Winner Based On Overall Score
        # ====================================================

        winner = ranking_df.iloc[0]

        st.subheader(
            ":material/emoji_events: Most Sensitive Technique (Drift Detection)"
        )

        st.write(
            f"**Technique:** {winner['Technique']}"
        )

        st.write(
            f"**Overall Score:** {winner['Overall_Score_100']}"
        )

        st.write(
            f"**Rank:** {winner['Rank']}"
        )

        st.write(
            f"**Root Cause Feature:** {winner['Root_Cause_Feature']}"
        )

        # ====================================================
        # AI Recommendation
        # ====================================================

        try:

            benchmark_info = {

                "Technique":
                    winner["Technique"],

                "Overall_Score":
                    winner["Overall_Score_100"],

                "Max_PSI":
                    winner["Max_PSI"],

                "Max_Gini_Drop":
                    winner["Max_Gini_Drop"],

                "Max_KS_Drop":
                    winner["Max_KS_Drop"],

                "Root_Cause_Feature":
                    winner["Root_Cause_Feature"]
            }

            with st.spinner(
                "Generating AI Recommendation..."
            ):

                benchmark_summary = (
                    generate_insight(
                        benchmark_info
                    )
                )

            st.subheader(
                ":material/smart_toy: AI Recommendation"
            )

            st.markdown(
                benchmark_summary
            )

        except Exception as e:

            st.warning(
                f"Could not generate benchmark summary: {e}"
            )

    # ====================================================
    # Ask About These Results (new feature): free-form Q&A over whatever
    # results are currently in session_state, classic and/or trend.
    # Placed at the top level of Tab 2 (outside both branches above) so it
    # shows regardless of which mode was last run.
    # ====================================================

    if _build_qa_context():
        st.divider()
        st.subheader(":material/chat: Ask About These Results")
        st.caption(
            "Ask a free-form question about whatever results are currently on screen. Each "
            "question is answered fresh from the actual numbers above -- not a running "
            "conversation the model remembers turn to turn."
        )

        if "qa_history" not in st.session_state:
            st.session_state["qa_history"] = []

        for q, a in st.session_state["qa_history"]:
            with st.chat_message("user"):
                st.write(q)
            with st.chat_message("assistant"):
                st.write(a)

        question = st.chat_input("Ask a question about the results above...")
        if question:
            try:
                with st.spinner("Thinking..."):
                    answer = answer_data_question(question, _build_qa_context())
            except Exception as e:
                answer = f"Could not generate an answer: {e}"
            st.session_state["qa_history"].append((question, answer))
            st.rerun()


# ============================================================
# TAB 3 — Cross-Technique Insights (task-flow step 4)
# ============================================================

with tab3:

    # ============================================================
    # Tab-scoped styling: left-accent cards for the executive summary,
    # matching the visual language used elsewhere in the app (colored
    # accent bar + pastel tint) without depending on any other tab's CSS.
    # ============================================================

    st.markdown(
        """
        <style>
        .xt-section-card { border-radius: 10px; padding: 0.1rem 1.1rem 0.9rem 1.1rem; margin-bottom: 1rem; }
        .xt-section-card .xt-accent { height: 4px; border-radius: 4px 4px 0 0; margin: 0 -1.1rem 0.75rem -1.1rem; }
        .xt-accent.blue { background: linear-gradient(90deg, #1B4F72, #2E86C1); }
        .xt-accent.amber { background: linear-gradient(90deg, #B5650A, #E8A23D); }
        .xt-accent.purple { background: linear-gradient(90deg, #5B3FA6, #8A6FD8); }
        .xt-accent.green { background: linear-gradient(90deg, #1E7A46, #3FB07A); }
        .xt-card-blue { background: #EAF3FB; }
        .xt-card-amber { background: #FCF3E3; }
        .xt-card-purple { background: #F1EDFB; }
        .xt-card-green { background: #E9F7EF; }
        .xt-kv-row { display: flex; justify-content: space-between; gap: 1rem; padding: 0.25rem 0; font-size: 0.95rem; }
        .xt-kv-key { color: #35424E; }
        .xt-kv-val { color: #1B1B1B; font-weight: 600; text-align: right; }
        .xt-subrow { display: flex; justify-content: space-between; gap: 1rem; padding: 0.15rem 0 0.15rem 1.1rem;
                     font-size: 0.87rem; color: #5A6570; }
        .xt-subrow .xt-kv-val { color: #35424E; font-weight: 500; }
        .xt-rank-badge {
            display: inline-block; background: rgba(0,0,0,0.06); border-radius: 6px;
            padding: 0.15rem 0.55rem; font-size: 0.9rem; font-weight: 700; margin: 0.6rem 0 0.2rem 0;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )

    def _xt_section_card(section_name: str, icon: str, color: str, rows: pd.DataFrame):
        with st.container(border=True):
            st.markdown(f'<div class="xt-accent {color}"></div>', unsafe_allow_html=True)
            # Material icon shortcodes (":material/x:") are only expanded by
            # Streamlit's own markdown parser on plain text -- embedding one
            # inside a raw unsafe_allow_html HTML string (as tried initially)
            # leaves it as literal, garbled text instead of rendering the
            # glyph, so this stays a separate plain st.markdown call rather
            # than the styled-but-broken HTML div tried first.
            st.markdown(f"{icon} **{section_name.title()}**")
            for _, r in rows.iterrows():
                key, value = str(r["Key"]), str(r["Value"])
                if key.strip().startswith("->"):
                    st.markdown(
                        f'<div class="xt-subrow"><span>{key.strip()}</span>'
                        f'<span class="xt-kv-val">{value}</span></div>',
                        unsafe_allow_html=True,
                    )
                elif key.lower().startswith("rank "):
                    st.markdown(f'<div class="xt-rank-badge">{key}</div>', unsafe_allow_html=True)
                    st.markdown(f'<div class="xt-kv-row"><span></span><span class="xt-kv-val">{value}</span></div>',
                                unsafe_allow_html=True)
                else:
                    st.markdown(
                        f'<div class="xt-kv-row"><span class="xt-kv-key">{key}</span>'
                        f'<span class="xt-kv-val">{value}</span></div>',
                        unsafe_allow_html=True,
                    )

    _XT_SECTION_STYLE = {
        "PORTFOLIO HEALTH": (":material/health_and_safety:", "blue", "xt-card-blue"),
        "TOP ROOT-CAUSE SEGMENTS": (":material/report:", "amber", "xt-card-amber"),
        "TOP WORST SEGMENTS": (":material/report:", "amber", "xt-card-amber"),
        "ROOT CAUSE ANALYSIS": (":material/search:", "purple", "xt-card-purple"),
        "RECOMMENDATIONS": (":material/checklist:", "green", "xt-card-green"),
    }

    st.header(":material/insights: Cross-Technique Insights", divider="gray")
    st.caption(
        "The worst-performing segments found by every segmentation technique, combined into one "
        "ranked view — so a segment several techniques agree on stands out from one only a single "
        "technique flagged."
    )

    cross_top10_df = st.session_state.get("cross_top10_df", pd.DataFrame())
    cross_exec_summary_df = st.session_state.get("cross_exec_summary_df", pd.DataFrame())
    trend_cross_top10_df = st.session_state.get("trend_cross_top10_df", pd.DataFrame())

    if cross_top10_df.empty and trend_cross_top10_df.empty:
        st.info(
            ":material/info: No data yet — run the benchmark or trend analysis in the "
            "**Technique Comparison** tab first, then come back here."
        )
    elif cross_top10_df.empty:
        pass  # only a trend run has been done -- the trend section below covers it
    else:
        st.caption(
            "Top-10 root-cause segments across all techniques, ranked by "
            "normalized Root_Cause_Score — a blend of drift, performance "
            "decay and population impact, not performance decay alone "
            "(task-flow step 4)."
        )
        st.subheader(":material/list_alt: Top 10 Root-Cause Segments (All Techniques)", divider="gray")
        st.dataframe(cross_top10_df, use_container_width=True)
        st.download_button(
            label=":material/download: Download Cross-Technique CSV (all columns)",
            data=cross_top10_df.to_csv(index=False),
            file_name="cross_technique_top10.csv",
            mime="text/csv",
            key="download_cross_top10",
        )

        if not cross_exec_summary_df.empty:
            st.subheader(":material/summarize: Cross-Technique Executive Summary", divider="gray")
            for section in cross_exec_summary_df["Section"].unique():
                icon, color, _ = _XT_SECTION_STYLE.get(section, (":material/notes:", "blue", "xt-card-blue"))
                sect_rows = cross_exec_summary_df[cross_exec_summary_df["Section"] == section]
                _xt_section_card(section, icon, color, sect_rows)

        st.subheader(":material/thermostat: Segment x Metric Heatmap", divider="gray")
        fig = segment_metric_heatmap(cross_top10_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(":material/bubble_chart: Bubble Chart — Population vs Gini Drop (size = exposure)",
                     divider="gray")
        fig = segment_bubble_chart(cross_top10_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(":material/water_drop: SIS Waterfall — #1 Worst Segment", divider="gray")
        fig = sis_waterfall_chart(cross_top10_df.iloc[0])
        if fig is not None:
            st.pyplot(fig)

    # ====================================================
    # Cross-Technique Trend Insights (taskflow step 4, trend version) --
    # separate from the classic section above, shown when a trend-analysis
    # run has populated it, regardless of whether a classic run has too.
    # ====================================================

    if not trend_cross_top10_df.empty:
        st.divider()
        st.header(":material/trending_up: Cross-Technique Trend Insights", divider="gray")
        st.caption(
            "Top-10 root-cause segments across all techniques and all selected months, "
            "ranked by normalized Root_Cause_Score_Trend (Root_Cause_Score with SIS "
            "boosted by each segment's Trend_Impact_Score). The table below shows the "
            "core columns for readability; the downloadable CSV includes every metric "
            "(PSI, AUC/Gini/KS, bad rate, exposure, SHAP, calibration, and more)."
        )

        trend_display_cols = [
            c for c in [
                "Overall_Rank", "Technique", "Discovered_By", "Segment_Definition",
                "Periods_Appeared", "Total_Periods", "Appeared_In", "Frequency",
                "Recency_Factor", "Consistency_Score", "Trend_Impact_Score",
                "Normalized_Root_Cause_Score",
            ] if c in trend_cross_top10_df.columns
        ]
        st.subheader(":material/list_alt: Top 10 Root-Cause Segments (All Techniques, Trend-Adjusted)",
                     divider="gray")
        st.dataframe(trend_cross_top10_df[trend_display_cols], use_container_width=True)
        st.download_button(
            label=":material/download: Download Cross-Technique Trend CSV (all columns)",
            data=trend_cross_top10_df.to_csv(index=False),
            file_name="cross_technique_trend_top10.csv",
            mime="text/csv",
            key="download_cross_trend_top10",
        )

        st.subheader(":material/thermostat: Segment x Metric Heatmap (Trend)", divider="gray")
        fig = segment_metric_heatmap(trend_cross_top10_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(":material/bubble_chart: Bubble Chart — Population vs Gini Drop (Trend)", divider="gray")
        fig = segment_bubble_chart(trend_cross_top10_df)
        if fig is not None:
            st.pyplot(fig)

        st.subheader(":material/water_drop: SIS Waterfall — #1 Most Persistent Root Cause", divider="gray")
        fig = sis_waterfall_chart(trend_cross_top10_df.iloc[0])
        if fig is not None:
            st.pyplot(fig)


# ============================================================
# TAB 4 — Home (Agent / Tools / Utilities conversational layer)
# ============================================================
#
# Additive-only: this tab does not read or write any session_state key used
# by Tab 1/2/3 (qa_history, summary_df, cross_top10_df, cross_exec_summary_df,
# trend_*), and its own widget keys (home_dev_upload/home_mon_upload) are
# distinct from Tab 1's (tab1_dev_upload/tab1_mon_upload).

with tab_home:

    # ============================================================
    # Home-tab-only styling: welcome banner, step tracker, card
    # accents, and the sticky right-hand chat panel.
    # ============================================================

    st.markdown(
        """
        <style>
        .home-welcome {
            background: linear-gradient(135deg, #EAF1F8 0%, #F3F0FC 100%);
            border-radius: 14px;
            padding: 1.5rem 1.75rem;
            margin-bottom: 1.5rem;
        }
        .home-welcome-title { font-size: 1.5rem; font-weight: 700; color: #1B4F72; margin-bottom: 0.25rem; }
        .home-welcome-subtitle { font-size: 1rem; color: #5A6570; margin-bottom: 1.1rem; }

        .home-steps { display: flex; align-items: center; flex-wrap: wrap; }
        .home-step { display: flex; align-items: center; gap: 0.55rem; }
        .home-step-circle {
            width: 30px; height: 30px; border-radius: 50%; flex-shrink: 0;
            display: flex; align-items: center; justify-content: center;
            font-weight: 700; font-size: 0.85rem;
        }
        .home-step-circle.done { background: #1B4F72; color: #fff; }
        .home-step-circle.active { background: #2E86C1; color: #fff; box-shadow: 0 0 0 4px rgba(46,134,193,0.22); }
        .home-step-circle.upcoming { background: #E3E8ED; color: #8592A0; }
        .home-step-label { font-weight: 600; font-size: 0.92rem; color: #1B1B1B; white-space: nowrap; }
        .home-step-label.upcoming { color: #8592A0; }
        .home-step-connector { flex: 1 1 24px; min-width: 24px; height: 2px; background: #D6DCE3; margin: 0 0.7rem; }
        .home-step-connector.done { background: #1B4F72; }

        .home-card-accent { height: 4px; border-radius: 4px 4px 0 0; margin: -1rem -1rem 0.85rem -1rem; }
        .home-card-accent.blue { background: linear-gradient(90deg, #1B4F72, #2E86C1); }
        .home-card-accent.green { background: linear-gradient(90deg, #1E7A46, #3FB07A); }
        .home-card-accent.amber { background: linear-gradient(90deg, #B5650A, #E8A23D); }
        .home-card-accent.purple { background: linear-gradient(90deg, #5B3FA6, #8A6FD8); }

        .home-preview-card { text-align: center; padding: 0.4rem 0.2rem; }
        .home-preview-card .icon { font-size: 1.6rem; }

        /* Pastel card fills -- subtle tint behind each card, keyed via
           st.container(key=...), which Streamlit exposes as a
           .st-key-<name> class on the container's own wrapper div. */
        .st-key-home_card_dev, .st-key-home_pv2 { background: #EAF3FB !important; border-radius: 10px; }
        .st-key-home_card_mon, .st-key-home_pv4 { background: #E9F7EF !important; border-radius: 10px; }
        .st-key-home_card_dq, .st-key-home_pv1 { background: #FCF3E3 !important; border-radius: 10px; }
        .st-key-home_card_dd { background: #EAF3FB !important; border-radius: 10px; }
        .st-key-home_card_seg, .st-key-home_pv3 { background: #F1EDFB !important; border-radius: 10px; }
        /* ============================================================
           RCA Agent chat panel -- Copilot Chat-style docked sidebar.
           Fixed to the viewport (not `sticky`: sticky only holds within
           its own column's box, which on a long results page ends
           wherever that column's content ends, so the panel scrolled out
           of view near the bottom -- fixed anchors it to the window
           itself instead, the way an IDE's chat panel is unaffected by
           how long the file being edited is).
           White/neutral body with a hairline border + soft shadow instead
           of a filled lavender card, so it reads as a docked panel that
           belongs to the app rather than a separate colored widget. ---- */
        .st-key-home_chat_panel {
            background: #FFFFFF !important;
            border: 1px solid #E4E9EF;
            border-radius: 12px;
            position: fixed;
            top: 84px;
            right: 28px;
            width: 400px;
            height: calc(100vh - 110px);
            overflow-y: auto;
            overflow-x: hidden;
            box-shadow: -8px 0 28px rgba(20, 45, 70, 0.10), 0 4px 18px rgba(20, 45, 70, 0.08);
            z-index: 9998;
            padding: 0 !important;
        }
        /* Horizontal gutter for every direct child row (caption, chat
           messages, empty-state, quick actions) -- the header and composer
           rows override this with their own padding since they're
           sticky/bordered full-bleed bars. */
        .st-key-home_chat_panel > * {
            padding-left: 1.1rem;
            padding-right: 1.1rem;
        }

        /* Compact fixed header: icon + "RCA Agent" + status line, close
           button on the right -- sticky to the panel's own scroll area
           (not the page), so it reads as a fixed header rather than
           scrolling away with the conversation. It's the columns() call
           right at the top of the panel, so it's the first stLayoutWrapper
           child in DOM order. */
        .st-key-home_chat_panel > [data-testid="stLayoutWrapper"]:first-of-type {
            position: sticky;
            top: 0;
            z-index: 3;
            background: #FFFFFF;
            border-bottom: 1px solid #EDF1F5;
            padding: 0.7rem 0.6rem 0.7rem 1.1rem;
        }
        /* Collapse control sitting at the top of the open panel -- same
           small white "chip" style as the launcher below (just with the
           agent icon instead of a chevron), so opening/closing reads as
           one consistent toggle rather than two different button styles. */
        .st-key-home_chat_panel_close button {
            border-radius: 8px !important;
            width: 32px !important;
            height: 32px !important;
            padding: 0 !important;
            background: #FFFFFF !important;
            border: 1px solid #E4E9EF !important;
            color: #35424E !important;
            box-shadow: 0 1px 4px rgba(20, 45, 70, 0.10);
        }
        .st-key-home_chat_panel_close button:hover { background: #F1F3F6 !important; border-color: #D6DCE3 !important; }

        /* Chat input stays pinned to the bottom of the panel's own scroll
           area (not the page) while message history scrolls above it --
           it's a direct child of the panel, so sticky here is anchored to
           the panel's internal scrollbar, not the outer page. */
        .st-key-home_chat_panel > [data-testid="stElementContainer"]:has(> [data-testid="stChatInput"]) {
            position: sticky;
            bottom: 0;
            background: #FFFFFF;
            border-top: 1px solid #EDF1F5;
            padding: 0.6rem 1.1rem 0.85rem 1.1rem;
            margin-top: 0.4rem;
            z-index: 3;
        }
        .st-key-home_chat_panel [data-testid="stChatInput"] textarea {
            font-size: 13.5px !important;
        }

        /* Chat bubbles: user on the right in a subtle rounded pill, agent
           on the left with a small avatar and no card/background -- the
           opposite of Streamlit's default (both roles identically
           left-aligned in a plain row). */
        /* Role is detected via the content div's aria-label ("Chat message
           from user"/"from assistant") rather than the avatar's own
           data-testid -- a custom avatar= string (used below for the
           assistant's 🤖 icon) drops the stChatMessageAvatarAssistant
           testid entirely, but the aria-label is always present on both
           roles regardless of avatar. */
        .st-key-home_chat_panel [data-testid="stChatMessage"] {
            padding: 0.15rem 0 !important;
            background: transparent !important;
            gap: 0.5rem;
        }
        .st-key-home_chat_panel [data-testid="stChatMessage"]:has([aria-label="Chat message from user"]) {
            flex-direction: row-reverse;
        }
        .st-key-home_chat_panel [aria-label="Chat message from user"] {
            background: #F1F3F6;
            border-radius: 14px 14px 3px 14px;
            padding: 0.5rem 0.85rem;
            max-width: 80%;
            margin-left: auto;
        }
        .st-key-home_chat_panel [aria-label="Chat message from assistant"] {
            background: transparent;
            padding: 0.15rem 0;
        }
        .st-key-home_chat_panel [data-testid="stChatMessageContent"] p {
            font-size: 13.5px !important;
            line-height: 1.55;
        }
        .st-key-home_chat_panel [data-testid="stChatMessageAvatarUser"],
        .st-key-home_chat_panel [data-testid="stChatMessage"] > div:first-child:not([data-testid]) {
            width: 26px !important;
            height: 26px !important;
            min-width: 26px !important;
            font-size: 0.9rem !important;
            display: flex !important;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
        }
        /* Neutral gray instead of Streamlit's default red accent for the
           user avatar -- keeps the panel on-brand (dark blue / neutral
           gray, minimal purple/red) rather than introducing a stray color. */
        .st-key-home_chat_panel [data-testid="stChatMessageAvatarUser"] {
            background: #E3E8ED !important;
            color: #5A6570 !important;
        }

        /* Empty-state suggestion chips + the persistent quick-action row
           above the composer -- small full-width outlined buttons instead
           of Streamlit's default filled button style, so they read as
           tappable prompts, not form actions. */
        .st-key-home_chat_empty button, .st-key-home_chat_quick button {
            background: #FFFFFF !important;
            border: 1px solid #E4E9EF !important;
            color: #35424E !important;
            font-size: 12.5px !important;
            font-weight: 500 !important;
            border-radius: 8px !important;
            padding: 0.4rem 0.6rem !important;
        }
        .st-key-home_chat_empty button:hover, .st-key-home_chat_quick button:hover {
            border-color: #2E86C1 !important;
            color: #1B4F72 !important;
            background: #F5FAFE !important;
        }
        .st-key-home_chat_empty button p { font-size: 12.5px !important; }
        .st-key-home_chat_quick button p { font-size: 12px !important; }

        /* Collapsed-state launcher: a round dark-blue badge fixed to the
           viewport edge, carrying the agent icon in white so it reads as
           "open the RCA Agent" at a glance. Shown only while the panel is
           closed (see the home_chat_open session-state branch below); the
           panel's own close button takes over once it's expanded, so the
           two never overlap. */
        .st-key-home_chat_toggle_wrap {
            position: fixed;
            top: 92px;
            right: 28px;
            z-index: 9999;
            width: fit-content !important;
        }
        .st-key-home_chat_toggle_wrap > div,
        .st-key-home_chat_toggle_wrap [data-testid="stVerticalBlockBorderWrapper"],
        .st-key-home_chat_toggle_wrap [data-testid="stVerticalBlock"],
        .st-key-home_chat_toggle_wrap [data-testid="element-container"] {
            width: fit-content !important;
        }
        .st-key-home_chat_toggle_wrap button {
            border-radius: 50% !important;
            width: 50px !important;
            height: 50px !important;
            padding: 0 !important;
            background: linear-gradient(135deg, #1B4F72, #2E86C1) !important;
            box-shadow: 0 4px 14px rgba(27, 79, 114, 0.38);
            border: none !important;
        }
        .st-key-home_chat_toggle_wrap button p,
        .st-key-home_chat_toggle_wrap button span {
            color: #FFFFFF !important;
            font-size: 1.5rem !important;
        }
        .st-key-home_chat_toggle_wrap button:hover { filter: brightness(1.12); }

        @media (max-width: 900px) {
            .st-key-home_chat_panel { width: calc(100vw - 24px); right: 12px; }
        }

        /* ---- Pastel result blocks: DQ = amber, DD = blue, SEG = purple,
           matching the Analysis Options card accents above -- plus a
           slightly larger base font so result content reads more easily. ---- */
        .st-key-home_results_dq, .st-key-home_results_dd, .st-key-home_results_seg {
            border-radius: 14px;
            padding: 1.35rem 1.6rem 1.1rem 1.6rem;
            margin-bottom: 1.4rem;
            font-size: 1.05rem;
        }
        .st-key-home_results_dq { background: #FCF3E3 !important; }
        .st-key-home_results_dd { background: #EAF3FB !important; }
        .st-key-home_results_seg { background: #F1EDFB !important; }

        .result-subheading {
            display: inline-block;
            font-weight: 700;
            font-size: 1.08rem;
            padding: 0.3rem 0.9rem;
            border-radius: 7px;
            margin: 0.9rem 0 0.6rem 0;
        }
        .result-subheading.amber { background: #F2D8A0; color: #7A4A04; }
        .result-subheading.blue { background: #C3DEF5; color: #1B4F72; }
        .result-subheading.purple { background: #DACBF7; color: #4A3080; }

        /* "What You Get" cards sit in one row -- without a shared min-height
           each one sizes to its own description length, so a 1-line caption
           card ends up visibly shorter than a 2-line one next to it.
           min-height only needs to clear the tallest card's own natural
           content (measured ~193px live, from "Comparative Insights"
           wrapping its title to 2 lines) -- a larger value just adds dead
           space below the text for no reason. */
        .st-key-home_pv1, .st-key-home_pv2, .st-key-home_pv3, .st-key-home_pv4 {
            min-height: 193px;
            display: flex;
            flex-direction: column;
        }

        /* Same fix for the Analysis Options cards -- all 3 captions now
           wrap to 2 lines and measure ~279px live, so the checkbox (last
           child) sits flush under the text with no dead space, while
           still guaranteeing all 3 checkboxes line up horizontally even
           if a caption's wrap length drifts slightly from a future edit. */
        .st-key-home_card_dq, .st-key-home_card_dd, .st-key-home_card_seg {
            min-height: 279px;
            display: flex;
            flex-direction: column;
        }
        .st-key-home_card_dq > *:last-child,
        .st-key-home_card_dd > *:last-child,
        .st-key-home_card_seg > *:last-child {
            margin-top: auto;
        }
        /* Larger, bolder card title ("Data Quality (DQ)" etc.) -- targets
           the title's own <p> specifically (not the accent-bar div above
           it, which has no <p> since it's a bare block-HTML fragment with
           no text content to wrap). */
        .st-key-home_card_dq [data-testid="stMarkdownContainer"] p,
        .st-key-home_card_dd [data-testid="stMarkdownContainer"] p,
        .st-key-home_card_seg [data-testid="stMarkdownContainer"] p {
            font-size: 1.3rem !important;
            margin-bottom: 0.35rem;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )

    def _home_df_has_rows(key: str) -> bool:
        df = st.session_state.get(key)
        return isinstance(df, pd.DataFrame) and not df.empty

    def _home_step_state(done: bool, prior_step_done: bool) -> str:
        if done:
            return "done"
        return "active" if prior_step_done else "upcoming"

    def _home_step(n, label, state):
        # Plain HTML checkmark entity, not the Material-icon shortcode --
        # this string is injected via unsafe_allow_html, and Streamlit's
        # icon-shortcode substitution isn't guaranteed to run inside raw
        # HTML the way it does for native calls like st.header/st.button.
        circle_content = "&#10003;" if state == "done" else str(n)
        label_cls = "upcoming" if state == "upcoming" else ""
        return (
            f'<div class="home-step">'
            f'<div class="home-step-circle {state}">{circle_content}</div>'
            f'<span class="home-step-label {label_cls}">{label}</span>'
            f'</div>'
        )

    def _home_render_banner(slot):
        # Reads widget/result state via session_state (by key) rather than
        # live variables -- this is called from further down the script
        # (after the Run button's click handler has already updated
        # session_state this same rerun), so it reflects the just-completed
        # run immediately instead of lagging one interaction behind. A
        # plain st.markdown() call positioned up here at the top of the
        # script would only ever see session_state as it was BEFORE the
        # button handler below ran -- Streamlit executes top to bottom
        # within a single rerun, so an early read can't see a later write
        # from the same pass. st.empty() is what makes "render at the top,
        # but with data computed lower down" possible: the slot keeps its
        # position on the page regardless of when it's filled.
        home_step1_done = bool(
            st.session_state.get("home_run_dq")
            or st.session_state.get("home_run_dd")
            or st.session_state.get("home_run_seg")
        )
        home_step2_done = st.session_state.get("home_last_run_selection") is not None
        home_step3_done = any([
            st.session_state.get("home_dq_results"),
            st.session_state.get("home_drift_results"),
            st.session_state.get("home_seg_results"),
        ])
        # Tab 2 (Technique Comparison) writes results under these keys on a
        # successful classic or trend run -- reused here rather than
        # duplicated, so step 4 reflects whether that tab has actually been
        # run, not just whether Home's own results exist.
        home_step4_done = (
            _home_df_has_rows("summary_df")
            or _home_df_has_rows("cross_top10_df")
            or _home_df_has_rows("trend_df")
        )

        _steps_state = [
            ("Select Options", "done" if home_step1_done else "active"),
            ("Upload &amp; Run", _home_step_state(home_step2_done, home_step1_done)),
            ("View Results", _home_step_state(home_step3_done, home_step2_done)),
            ("Compare Techniques", _home_step_state(home_step4_done, home_step3_done)),
        ]
        _steps_html = ""
        for i, (label, state) in enumerate(_steps_state, start=1):
            _steps_html += _home_step(i, label, state)
            if i < len(_steps_state):
                connector_cls = "done" if state == "done" else ""
                _steps_html += f'<div class="home-step-connector {connector_cls}"></div>'

        slot.markdown(
            f"""
            <div class="home-welcome">
                <div class="home-welcome-title">Welcome to Model RCA Studio</div>
                <div class="home-welcome-subtitle">Upload data, run Data Quality / Drift / Segmentation checks with
                    default parameters, then ask the Model RCA Agent about the results — it explains what was already
                    computed, it does not run anything new.</div>
                <div class="home-steps">{_steps_html}</div>
                <div class="home-welcome-subtitle" style="margin-top:0.75rem; margin-bottom:0;">
                    Step 4 — Compare Techniques — happens in the <strong>Technique Comparison</strong> tab above,
                    once you have results here.
                </div>
            </div>
            """,
            unsafe_allow_html=True,
        )

    home_banner_slot = st.empty()
    _home_render_banner(home_banner_slot)

    # ============================================================
    # Home-tab helper functions
    # ============================================================

    _DRIFT_STATUS_RANK = {"stable": 0, "monitor": 1, "notable": 1, "shift": 2, "critical": 2}

    def _home_drift_overall_status(drift_result: dict) -> str:
        """Worst label across every labeled sub-section, in plain terms."""
        worst = 0
        for key in ("csi", "ks", "entropy", "categorical_psi"):
            df = drift_result.get(key)
            if hasattr(df, "empty") and not df.empty and "label" in df.columns:
                for lbl in df["label"]:
                    worst = max(worst, _DRIFT_STATUS_RANK.get(str(lbl).lower(), 0))
        for key in ("score_psi", "target"):
            d = drift_result.get(key)
            if isinstance(d, dict) and d.get("label"):
                worst = max(worst, _DRIFT_STATUS_RANK.get(str(d["label"]).lower(), 0))
        return {0: "Stable", 1: "Monitor", 2: "Shift / Critical"}[worst]

    def _home_build_dq_glance_df(dq_results: dict, units: list) -> pd.DataFrame:
        rows = []
        for name in units:
            res = dq_results.get(name)
            if not res:
                continue
            rows.append({
                "Dataset": name,
                "Rows Profiled": len(res.get("profile", [])),
                "Readiness Score": res.get("readiness_score"),
                "Blockers": len(res.get("blockers", [])),
                "Governance Flags": len(res.get("governance", [])),
            })
        return pd.DataFrame(rows)

    def _home_build_pair_glance_df(units: list, drift_results: dict, seg_results: dict,
                                    dq_results: dict, run_dq: bool, run_dd: bool, run_seg: bool) -> pd.DataFrame:
        rows = []
        for name in units:
            row = {"Monitoring Dataset": name}
            if run_dq and name in dq_results:
                row["Monitoring Readiness Score"] = dq_results[name].get("readiness_score")
            if run_dd and name in drift_results:
                dr = drift_results[name]
                row["Overall Drift Status"] = _home_drift_overall_status(dr)
                score_psi = dr.get("score_psi") or {}
                target = dr.get("target") or {}
                row["Model Score PSI"] = score_psi.get("psi")
                row["Target Change (pp)"] = target.get("delta_pp")
            if run_seg and name in seg_results:
                _, _, cross_top10_df, _ = seg_results[name]
                if cross_top10_df is not None and not cross_top10_df.empty:
                    top = cross_top10_df.iloc[0]
                    row["Top Segment"] = top.get("Segment_Definition", "N/A")
                    row["Root-Cause Score"] = top.get("Normalized_Root_Cause_Score", top.get("Root_Cause_Score"))
            rows.append(row)
        return pd.DataFrame(rows)

    def _home_subheading(text: str, color: str):
        st.markdown(f'<div class="result-subheading {color}">{text}</div>', unsafe_allow_html=True)

    def _home_render_dq_detail(dq_result: dict, heading: str):
        if not dq_result:
            return
        _home_subheading(heading, "amber")
        st.metric("Readiness Score", f"{dq_result.get('readiness_score')}/100")
        st.caption(
            "This is the average, across every column, of each column's own Health Score — which itself "
            "blends how complete, how variable, how governance-clean, and how well-distributed that column is "
            "into one 0-100 number."
        )
        health = dq_result.get("health")
        if hasattr(health, "empty") and not health.empty:
            st.dataframe(health.rename(columns=COLUMN_RENAME_MAP), use_container_width=True, hide_index=True)
        blockers = dq_result.get("blockers")
        if hasattr(blockers, "empty") and not blockers.empty:
            st.caption("Columns that block modeling entirely (e.g. mostly missing, zero variance).")
            st.dataframe(blockers.rename(columns=COLUMN_RENAME_MAP), use_container_width=True, hide_index=True)
        governance = dq_result.get("governance")
        if hasattr(governance, "empty") and not governance.empty:
            st.caption("Columns flagged as identifiers, potential leakage, or privacy-sensitive.")
            st.dataframe(governance.rename(columns=COLUMN_RENAME_MAP), use_container_width=True, hide_index=True)
        profile = dq_result.get("profile")
        if hasattr(profile, "empty") and not profile.empty:
            with st.expander("Full Column Profile (advanced)"):
                st.dataframe(profile.rename(columns=COLUMN_RENAME_MAP), use_container_width=True, hide_index=True)

    def _home_section_present(value) -> bool:
        # A raw truthiness check crashes on a multi-row DataFrame ("truth
        # value of a DataFrame is ambiguous"); dict sections (score_psi,
        # target) and DataFrame sections need different emptiness checks.
        if value is None:
            return False
        if hasattr(value, "empty"):
            return not value.empty
        return bool(value)

    def _home_render_drift_detail(drift_result: dict):
        if not drift_result:
            return
        for group_name, keys in DRIFT_SECTION_GROUPS.items():
            present_keys = [k for k in keys if _home_section_present(drift_result.get(k))]
            if not present_keys:
                continue
            _home_subheading(group_name, "blue")
            for key in present_keys:
                value = drift_result[key]
                if isinstance(value, dict):
                    value = pd.DataFrame([value])
                if hasattr(value, "empty") and value.empty:
                    continue
                if key == "completeness":
                    # Completeness % alone doesn't say how much is actually
                    # missing -- show both, with Missing % positioned right
                    # before the Change column so the two readings sit together.
                    value = value.copy()
                    value["dev_missing_pct"] = (100 - value["dev_completeness_pct"]).round(2)
                    value["mon_missing_pct"] = (100 - value["mon_completeness_pct"]).round(2)
                    value = value[[
                        "name", "dev_completeness_pct", "mon_completeness_pct",
                        "dev_missing_pct", "mon_missing_pct", "delta_pp", "pattern",
                    ]]
                with st.expander(DRIFT_SECTION_LABELS[key], expanded=True):
                    st.caption(DRIFT_SECTION_EXPLANATIONS[key])
                    st.dataframe(
                        value.rename(columns=COLUMN_RENAME_MAP),
                        use_container_width=key not in {"csi", "ks", "entropy", "categorical_psi"},
                        hide_index=True,
                    )

    def _home_render_seg_detail(seg_result: tuple):
        if not seg_result:
            return
        summary_df, combined_segments_df, cross_top10_df, cross_exec_summary_df = seg_result
        _home_subheading("Per-Technique Summary", "purple")
        st.dataframe(summary_df, use_container_width=True)
        if cross_top10_df is not None and not cross_top10_df.empty:
            # The raw table has ~98 columns (confidence intervals, p-value
            # variants, technique-internal fields) -- show the curated,
            # grouped subset a business reader actually needs instead.
            present = [(raw, label) for raw, label in SEGMENTATION_TOP10_COLUMNS if raw in cross_top10_df.columns]
            curated = cross_top10_df[[raw for raw, _ in present]].rename(columns=dict(present))
            _home_subheading("Cross-Technique Top-10 Root-Cause Segments", "purple")
            st.dataframe(curated, use_container_width=True, hide_index=True)

    # ============================================================
    # Copilot-style chat toggle -- collapsed by default so the main
    # dashboard gets the full width; a floating pill button (fixed
    # top-right, like the GitHub Copilot Chat launcher) opens/closes
    # the right-hand agent panel on click.
    # ============================================================

    if "home_chat_open" not in st.session_state:
        st.session_state["home_chat_open"] = False

    # The launcher button is only shown while the panel is closed -- once
    # open, the panel's own in-header close button (see below) takes over,
    # so the two never have to share the same fixed top-right corner.
    if not st.session_state["home_chat_open"]:
        with st.container(key="home_chat_toggle_wrap"):
            if st.button(":material/smart_toy:", key="home_chat_toggle_btn",
                         help="Ask the Model RCA Agent"):
                st.session_state["home_chat_open"] = True
                st.rerun()

    if st.session_state["home_chat_open"]:
        # Reserve room for the fixed-position chat panel (400px wide, 28px
        # from the right edge) by shrinking the main content area itself,
        # rather than relying on st.columns' flex ratio for it. A column
        # whose only content is position:fixed collapses to ~0 width (its
        # box has nothing left in normal document flow to size itself
        # against), so the sibling column silently reclaims that space and
        # the fixed panel ends up floating OVER the main content -- hiding
        # text/tables behind it -- instead of the content narrowing to
        # make room for it, the way a real docked sidebar resizes its
        # neighbor.
        # `width` (not `margin-right`) is what actually shrinks it: the
        # container has an explicit `width: 100%` (not `width: auto`) from
        # Streamlit's own CSS, so a plain margin-right just pushes the box
        # 448px past its parent's edge -- an overflow, not a resize -- and
        # the browser silently pans to reveal it, sliding everything (even
        # the header) left instead of narrowing the content.
        # `align-self: flex-start` is needed too: stMain is a column flex
        # container with `align-items: center`, so a narrower child just
        # gets re-centered in the middle of the page (floating away from
        # the left edge) instead of staying pinned there once it shrinks.
        st.markdown(
            """
            <style>
            [data-testid="stMainBlockContainer"] {
                width: calc(100% - 448px) !important;
                align-self: flex-start !important;
                transition: width 0.15s ease;
            }
            </style>
            """,
            unsafe_allow_html=True,
        )
        home_main_col = st.container()
        home_chat_col = st.container()
    else:
        home_main_col = st.container()
        home_chat_col = None

    # ============================================================
    # Main column: analysis options, upload, run, results
    # ============================================================

    with home_main_col:

        st.subheader(":material/tune: Analysis Options", divider="gray")
        st.caption("Pick one or more checks to run with default parameters — pick options first, then upload "
                   "whichever dataset(s) that check needs.")

        home_col1, home_col2, home_col3 = st.columns(3)
        with home_col1:
            with st.container(border=True, key="home_card_dq"):
                st.markdown('<div class="home-card-accent amber"></div>', unsafe_allow_html=True)
                st.markdown(":material/fact_check: **Data Quality (DQ)**")
                st.caption("Profile one or more datasets independently — no baseline needed. Flags missing "
                           "values, low-variance columns, and governance risks like PII or target leakage.")
                home_run_dq = st.checkbox("Data Quality (DQ)", key="home_run_dq", label_visibility="collapsed")
        with home_col2:
            with st.container(border=True, key="home_card_dd"):
                st.markdown('<div class="home-card-accent blue"></div>', unsafe_allow_html=True)
                st.markdown(":material/show_chart: **Data Drift (DD)**")
                st.caption("Compare one baseline against one or more monitoring datasets. Measures population "
                           "and feature-level drift using PSI, CSI, and KS statistics.")
                home_run_dd = st.checkbox("Data Drift (DD)", key="home_run_dd", label_visibility="collapsed")
        with home_col3:
            with st.container(border=True, key="home_card_seg"):
                st.markdown('<div class="home-card-accent purple"></div>', unsafe_allow_html=True)
                st.markdown(":material/hub: **Segmentation (SEG)**")
                st.caption("Find root-cause segments for one baseline vs. one or more monitoring datasets. "
                           "Surfaces the segments and features driving the biggest performance drop.")
                home_run_seg = st.checkbox("Segmentation (SEG)", key="home_run_seg", label_visibility="collapsed")

        home_dq_only = home_run_dq and not home_run_dd and not home_run_seg
        home_pair_mode = home_run_dd or home_run_seg
        home_nothing_checked = not (home_run_dq or home_run_dd or home_run_seg)

        st.write("")

        home_dq_files: dict = {}
        home_dev_source = None
        home_dev_name = None
        home_mon_files: dict = {}

        if home_nothing_checked:
            st.info("Select at least one analysis option above to see the upload fields.")
        elif home_dq_only:
            st.subheader(":material/upload_file: Datasets to Profile", divider="gray")
            st.caption("Upload one or more CSVs — each is profiled independently. Leave empty to use the demo dataset.")
            with st.container(border=True, key="home_card_dev"):
                st.markdown('<div class="home-card-accent amber"></div>', unsafe_allow_html=True)
                home_dq_uploads = st.file_uploader(
                    "Drag & drop CSV file(s) here", type=["csv"], accept_multiple_files=True,
                    key="home_dq_multi_upload", label_visibility="collapsed",
                )
            if home_dq_uploads:
                for f in home_dq_uploads:
                    home_dq_files[f.name] = f
            else:
                home_dq_files[Path(DEV_FILE).name] = DEV_FILE
                st.caption(f"Using demo data — `{Path(DEV_FILE).name}`.")
        elif home_pair_mode:
            st.subheader(":material/upload_file: Upload Datasets", divider="gray")
            st.caption("One baseline dataset, plus one or more monitoring datasets. "
                       "If Data Quality is also checked, it profiles the baseline and every monitoring "
                       "dataset below too — no separate upload needed.")
            home_up_col1, home_up_col2 = st.columns(2)
            with home_up_col1:
                with st.container(border=True, key="home_card_dev"):
                    st.markdown('<div class="home-card-accent blue"></div>', unsafe_allow_html=True)
                    st.markdown(":material/database: **Development / Baseline Dataset**")
                    st.caption("Used as the training/baseline period for comparison.")
                    home_uploaded_dev = st.file_uploader(
                        "Drag & drop CSV file here", type=["csv"],
                        key="home_dev_upload", label_visibility="collapsed",
                    )
            with home_up_col2:
                with st.container(border=True, key="home_card_mon"):
                    st.markdown('<div class="home-card-accent green"></div>', unsafe_allow_html=True)
                    st.markdown(":material/cloud_upload: **Monitoring Dataset(s)**")
                    st.caption("One or more current/production periods to compare against the baseline.")
                    home_uploaded_mons = st.file_uploader(
                        "Drag & drop CSV file(s) here", type=["csv"], accept_multiple_files=True,
                        key="home_mon_upload", label_visibility="collapsed",
                    )

            if home_uploaded_dev is not None:
                home_dev_source = home_uploaded_dev
                home_dev_name = home_uploaded_dev.name
            else:
                home_dev_source = DEV_FILE
                home_dev_name = Path(DEV_FILE).name

            if home_uploaded_mons:
                for f in home_uploaded_mons:
                    home_mon_files[f.name] = f
            else:
                home_mon_files[Path(MON_FILE).name] = MON_FILE

            if home_uploaded_dev is None and not home_uploaded_mons:
                st.caption(
                    f"Using demo data — Development: `{Path(DEV_FILE).name}` · "
                    f"Monitoring: `{Path(MON_FILE).name}`."
                )

        st.write("")
        home_run_clicked = st.button(
            "Run Analysis", key="home_run_button", type="primary", icon=":material/play_arrow:"
        )

        if home_run_clicked:
            if home_nothing_checked:
                st.error("Select at least one of Data Quality, Data Drift, or Segmentation.")
            else:
                # Fresh run: clear every previous result so stale entries never
                # linger in the drill-down list after switching mode/files.
                st.session_state["home_dq_results"] = {}
                st.session_state["home_drift_results"] = {}
                st.session_state["home_seg_results"] = {}
                st.session_state["home_dev_filename"] = None
                st.session_state["home_qa_history"] = {}
                st.session_state["home_drill_selection"] = None
                st.session_state["home_last_run_selection"] = [
                    name for name, flag in
                    [("DQ", home_run_dq), ("DD", home_run_dd), ("SEG", home_run_seg)]
                    if flag
                ]

                if home_dq_only:
                    units = list(home_dq_files.keys())
                    progress = st.progress(0.0, text="Starting Data Quality profiling...")
                    for i, (name, source) in enumerate(home_dq_files.items()):
                        progress.progress(i / len(units), text=f"Profiling {name} ({i + 1}/{len(units)})...")
                        try:
                            df_i = pd.read_csv(source)
                            try:
                                schema_i = _auto_detect_schema(df_i)
                            except ValueError:
                                schema_i = SchemaConfig()
                            out = main_wrapper(
                                df_i, None, is_dq_req=True,
                                target_col=schema_i.target_col, id_cols=schema_i.id_cols,
                                feature_cols=schema_i.numeric_cols, categorical_cols=schema_i.categorical_cols,
                            )
                            st.session_state["home_dq_results"][name] = out.get("dq_dev")
                        except Exception as e:
                            st.warning(f"Data Quality failed for {name}: {e}")
                    progress.progress(1.0, text="Done"); progress.empty()
                    st.session_state["home_run_units"] = units
                    st.session_state["home_run_mode"] = "dq_only"

                elif home_pair_mode:
                    try:
                        home_dev_df = pd.read_csv(home_dev_source)
                        home_schema_cfg = _auto_detect_schema(home_dev_df)
                    except Exception as e:
                        home_dev_df = None
                        home_schema_cfg = None
                        st.warning(f"Could not auto-detect a schema for the baseline dataset: {e}. Run cancelled.")

                    if home_schema_cfg is not None:
                        if home_run_dq:
                            try:
                                dev_dq_out = main_wrapper(
                                    home_dev_df, None, is_dq_req=True,
                                    target_col=home_schema_cfg.target_col, id_cols=home_schema_cfg.id_cols,
                                    feature_cols=home_schema_cfg.numeric_cols,
                                    categorical_cols=home_schema_cfg.categorical_cols,
                                )
                                st.session_state["home_dq_results"][home_dev_name] = dev_dq_out.get("dq_dev")
                                st.session_state["home_dev_filename"] = home_dev_name
                            except Exception as e:
                                st.warning(f"Data Quality failed for baseline dataset {home_dev_name}: {e}")

                        mon_items = list(home_mon_files.items())
                        progress = st.progress(0.0, text="Starting...")
                        for i, (name, source) in enumerate(mon_items):
                            progress.progress(
                                i / len(mon_items),
                                text=f"Running analysis for {name} ({i + 1}/{len(mon_items)})...",
                            )
                            try:
                                mon_df = pd.read_csv(source)
                            except Exception as e:
                                st.warning(f"Could not read {name}: {e}")
                                continue

                            if home_run_dq or home_run_dd:
                                try:
                                    out = main_wrapper(
                                        home_dev_df, mon_df,
                                        is_dq_req=home_run_dq, is_drift_req=home_run_dd,
                                        target_col=home_schema_cfg.target_col, score_col=home_schema_cfg.score_col,
                                        id_cols=home_schema_cfg.id_cols, feature_cols=home_schema_cfg.numeric_cols,
                                        categorical_cols=home_schema_cfg.categorical_cols,
                                    )
                                    if home_run_dq:
                                        st.session_state["home_dq_results"][name] = out.get("dq_mon")
                                    if home_run_dd:
                                        st.session_state["home_drift_results"][name] = out.get("drift")
                                except Exception as e:
                                    st.warning(f"Data Quality / Data Drift failed for {name}: {e}")

                            if home_run_seg:
                                try:
                                    st.session_state["home_seg_results"][name] = benchmark_all_techniques(
                                        home_dev_df, mon_df, save_outputs=False, schema_cfg=home_schema_cfg,
                                    )
                                except Exception as e:
                                    st.warning(f"Segmentation failed for {name}: {e}")

                        progress.progress(1.0, text="Done"); progress.empty()
                        st.session_state["home_run_units"] = [name for name, _ in mon_items]
                        st.session_state["home_run_mode"] = "pair"

            # Re-render the banner now that this click's results (if any)
            # are in session_state -- the first render at the top of the
            # script ran before this button's handler, so it showed
            # pre-click state.
            _home_render_banner(home_banner_slot)

        # ---- Render results from session_state (survives reruns) ----

        home_dq_results = st.session_state.get("home_dq_results", {})
        home_drift_results = st.session_state.get("home_drift_results", {})
        home_seg_results = st.session_state.get("home_seg_results", {})
        home_run_mode = st.session_state.get("home_run_mode")
        home_run_units = st.session_state.get("home_run_units", [])
        home_dev_filename = st.session_state.get("home_dev_filename")
        home_last_selection = st.session_state.get("home_last_run_selection") or []

        home_has_any_result = bool(home_dq_results or home_drift_results or home_seg_results)

        if home_has_any_result:
            st.subheader(":material/list_alt: Results at a Glance", divider="gray")
            if home_run_mode == "dq_only":
                glance_df = _home_build_dq_glance_df(home_dq_results, home_run_units)
            else:
                glance_df = _home_build_pair_glance_df(
                    home_run_units, home_drift_results, home_seg_results, home_dq_results,
                    "DQ" in home_last_selection, "DD" in home_last_selection, "SEG" in home_last_selection,
                )
            if not glance_df.empty:
                st.dataframe(glance_df, use_container_width=True, hide_index=True)

            if home_run_units:
                default_idx = (
                    home_run_units.index(st.session_state["home_drill_selection"])
                    if st.session_state.get("home_drill_selection") in home_run_units else 0
                )
                home_selected = st.selectbox(
                    "View full details for:", home_run_units, index=default_idx, key="home_drill_select",
                )
                st.session_state["home_drill_selection"] = home_selected

                if home_run_mode == "dq_only":
                    with st.container(key="home_results_dq"):
                        st.subheader(":material/fact_check: Data Quality Results", divider="gray")
                        _home_render_dq_detail(home_dq_results.get(home_selected), home_selected)
                else:
                    if (home_dev_filename and home_dev_filename in home_dq_results) or home_selected in home_dq_results:
                        with st.container(key="home_results_dq"):
                            if home_dev_filename and home_dev_filename in home_dq_results:
                                st.subheader(":material/fact_check: Data Quality Results", divider="gray")
                                _home_render_dq_detail(
                                    home_dq_results.get(home_dev_filename), f"{home_dev_filename} (Development/Baseline)"
                                )
                            if home_selected in home_dq_results:
                                if not home_dev_filename:
                                    st.subheader(":material/fact_check: Data Quality Results", divider="gray")
                                _home_render_dq_detail(home_dq_results.get(home_selected), f"{home_selected} (Monitoring)")
                    if home_selected in home_drift_results:
                        with st.container(key="home_results_dd"):
                            st.subheader(":material/show_chart: Data Drift Results", divider="gray")
                            st.caption(f"Baseline `{home_dev_filename or Path(DEV_FILE).name}` vs. monitoring `{home_selected}`.")
                            _home_render_drift_detail(home_drift_results.get(home_selected))
                    if home_selected in home_seg_results:
                        with st.container(key="home_results_seg"):
                            st.subheader(":material/hub: Segmentation Results", divider="gray")
                            _home_render_seg_detail(home_seg_results.get(home_selected))

        # ---- "What You Get" preview, shown only before the first run ----

        if not home_has_any_result:
            st.subheader(":material/auto_awesome: What You Get", divider="gray")
            home_pv1, home_pv2, home_pv3, home_pv4 = st.columns(4)
            _home_previews = [
                (home_pv1, "home_pv1", ":material/pie_chart:", "Data Quality Metrics",
                 "Missing values, outliers, data completeness and more."),
                (home_pv2, "home_pv2", ":material/show_chart:", "Drift Analysis",
                 "PSI, KS test, distribution comparisons and drift visualizations."),
                (home_pv3, "home_pv3", ":material/hub:", "Segmentation (RCA)",
                 "AutoSlicer, DLT, Feature Binning and more to find root causes."),
                (home_pv4, "home_pv4", ":material/lightbulb:", "Comparative Insights",
                 "Compare techniques and generate actionable insights."),
            ]
            for col, card_key, icon, title, desc in _home_previews:
                with col:
                    with st.container(border=True, key=card_key):
                        st.markdown(f"{icon} **{title}**")
                        st.caption(desc)

    # ============================================================
    # Right column: Copilot-style chat panel
    # ============================================================

    if home_chat_col is not None:
        with home_chat_col:

            home_dq_results = st.session_state.get("home_dq_results", {})
            home_drift_results = st.session_state.get("home_drift_results", {})
            home_seg_results = st.session_state.get("home_seg_results", {})
            home_run_mode = st.session_state.get("home_run_mode")
            home_selected = st.session_state.get("home_drill_selection")
            home_dev_filename = st.session_state.get("home_dev_filename")

            if home_run_mode == "dq_only":
                home_dq_ctx = build_dq_context(home_dq_results.get(home_selected)) if home_selected else ""
                home_drift_ctx = ""
                home_seg_ctx = ""
                home_glance_df = _home_build_dq_glance_df(
                    home_dq_results, st.session_state.get("home_run_units", [])
                )
            else:
                dev_dq = home_dq_results.get(home_dev_filename) if home_dev_filename else None
                mon_dq = home_dq_results.get(home_selected) if home_selected else None
                home_dq_ctx = build_dq_context(dev_dq, mon_dq) if (dev_dq or mon_dq) else ""
                home_drift_ctx = (
                    build_drift_context(home_drift_results.get(home_selected)) if home_selected in home_drift_results else ""
                )
                home_seg_ctx = (
                    build_seg_context(*home_seg_results[home_selected]) if home_selected in home_seg_results else ""
                )
                home_last_selection = st.session_state.get("home_last_run_selection") or []
                home_glance_df = _home_build_pair_glance_df(
                    st.session_state.get("home_run_units", []), home_drift_results, home_seg_results, home_dq_results,
                    "DQ" in home_last_selection, "DD" in home_last_selection, "SEG" in home_last_selection,
                )

            home_glance_ctx = (
                "=== All Datasets At a Glance ===\n" + home_glance_df.to_string(index=False)
                if not home_glance_df.empty else ""
            )

            def _home_ask(question: str):
                if "home_qa_history" not in st.session_state or not isinstance(st.session_state["home_qa_history"], dict):
                    st.session_state["home_qa_history"] = {}
                history = st.session_state["home_qa_history"].setdefault(home_selected, [])
                try:
                    with st.spinner("Thinking..."):
                        answer = rca_answer(question, home_dq_ctx, home_drift_ctx, home_seg_ctx, home_glance_ctx)
                except Exception as e:
                    answer = f"Could not generate an answer: {e}"
                history.append((question, answer))
                st.rerun()

            with st.container(border=True, key="home_chat_panel"):
                home_chat_head_col, home_chat_close_col = st.columns([6, 1], vertical_alignment="center")
                with home_chat_head_col:
                    st.markdown(
                        """
                        <div style="display:flex; align-items:center; gap:0.6rem;">
                            <div style="width:32px; height:32px; border-radius:9px; flex-shrink:0;
                                        background:linear-gradient(135deg,#1B4F72,#2E86C1);
                                        display:flex; align-items:center; justify-content:center; font-size:1rem;">
                                🤖
                            </div>
                            <div style="line-height:1.25;">
                                <div style="font-size:15.5px; font-weight:600; color:#1B1B1B;">RCA Agent</div>
                                <div style="font-size:11.5px; color:#8592A0; display:flex; align-items:center; gap:0.4rem;">
                                    Model monitoring assistant
                                    <span style="display:inline-flex; align-items:center; gap:0.28rem; color:#1E7A46; font-weight:600;">
                                        <span style="width:6px; height:6px; border-radius:50%; background:#3FB07A;"></span>Ready
                                    </span>
                                </div>
                            </div>
                        </div>
                        """,
                        unsafe_allow_html=True,
                    )
                with home_chat_close_col:
                    if st.button(":material/smart_toy:", key="home_chat_panel_close", help="Collapse"):
                        st.session_state["home_chat_open"] = False
                        st.rerun()

                if not (home_dq_ctx or home_drift_ctx or home_seg_ctx):
                    st.caption(
                        "Run Data Quality, Data Drift, and/or Segmentation on the left to start chatting — "
                        "the agent only explains results that have actually been computed, so there's nothing "
                        "to ask about yet."
                    )
                else:
                    grounding = f"**{home_selected}**"
                    if home_run_mode == "pair" and home_dev_filename:
                        grounding += f" (vs. baseline **{home_dev_filename}**)"
                    st.caption(f"Grounded in {grounding}. Switch the dropdown on the left to ground the chat "
                               "in a different dataset.")

                    if "home_qa_history" not in st.session_state or not isinstance(st.session_state["home_qa_history"], dict):
                        st.session_state["home_qa_history"] = {}
                    home_qa_history = st.session_state["home_qa_history"].setdefault(home_selected, [])

                    if not home_qa_history:
                        with st.container(key="home_chat_empty"):
                            st.markdown(
                                """
                                <div style="text-align:center; padding:1.5rem 0.5rem 0.75rem 0.5rem;">
                                    <div style="font-size:1.8rem;">🤖</div>
                                    <div style="font-size:14.5px; font-weight:600; color:#1B1B1B; margin-top:0.35rem;">RCA Agent</div>
                                    <div style="font-size:12.5px; color:#8592A0; margin-top:0.2rem;">
                                        Ask questions about your computed monitoring results.
                                    </div>
                                </div>
                                """,
                                unsafe_allow_html=True,
                            )
                            for suggestion in [
                                "What changed in the data?",
                                "Which segments are flagged as worst-performing?",
                                "Explain the main root cause.",
                            ]:
                                if st.button(suggestion, key=f"home_chat_suggest_{suggestion}", use_container_width=True):
                                    _home_ask(suggestion)
                    else:
                        for q, a in home_qa_history:
                            with st.chat_message("user"):
                                st.write(q)
                            with st.chat_message("assistant", avatar="🤖"):
                                st.write(a)

                    with st.container(key="home_chat_quick"):
                        quick_cols = st.columns(3)
                        quick_actions = [
                            ("Explain drift", "Is there any data drift, and what does it mean?"),
                            ("Explain RCA", "What is the root cause of the observed changes?"),
                            ("Summarize results", "Summarize the key results in a few sentences."),
                        ]
                        for col, (label, question) in zip(quick_cols, quick_actions):
                            with col:
                                if st.button(label, key=f"home_chat_quick_{label}", use_container_width=True):
                                    _home_ask(question)

                    home_question = st.chat_input("Ask about your RCA results...")
                    if home_question:
                        _home_ask(home_question)
