"""
utils/display_labels.py
Plain-language labels, short explanations, grouping, and column renames for
the Data Quality / Data Drift result sections produced by
sas_macros/dq_drift_python_translation.py. Centralized here so the Home
tab's UI and the RCA Agent's LLM context (tools/data_drift_tool.py) use the
same wording.
"""

SECTION_LABELS = {
    "schema": "Structural Changes (Schema)",
    "completeness": "Missing-Data Drift (Completeness)",
    "csi": "Feature Stability (Population Stability Index)",
    "distribution": "Distribution Shape Changes",
    "ks": "Distribution Shape Test (KS Statistic)",
    "entropy": "Category Diversity Drift (Entropy)",
    "categorical_psi": "Category Mix Stability (Population Stability Index)",
    "score_psi": "Model Prediction Drift (Score)",
    "target": "Actual Outcome Drift (Target)",
}

SECTION_EXPLANATIONS = {
    "schema": "Flags columns that were added, removed, or changed data type between the development and monitoring data.",
    "completeness": "Compares how much data is missing in each column between the two periods, and whether it's getting better or worse.",
    "csi": "Measures how much each numeric feature's range of values has shifted, using the Population Stability Index (PSI). Below 0.10 = stable, 0.10-0.25 = monitor, above 0.25 = significant shift.",
    "distribution": "Shows the actual mean/min/max/spread/shape of each numeric feature side by side for both periods, plus how much each one changed.",
    "ks": "A second, independent statistical test of whether a feature's distribution shape has shifted -- used to confirm the PSI finding above.",
    "entropy": "Measures whether a category column (e.g. region) has become more or less evenly spread across its categories.",
    "categorical_psi": "Measures how much each category column's mix of values has shifted between the two periods, using the same PSI method as numeric features.",
    "score_psi": "Checks whether the model's own predicted scores have shifted between the two periods -- a sign the model's behavior itself is changing.",
    "target": "Compares the real-world outcome rate (e.g. % who actually defaulted) between the two periods -- the actual result, not a prediction.",
}

SECTION_GROUPS = {
    "Structural Drift": ["schema", "completeness"],
    "Feature / Population Drift": ["csi", "distribution", "ks", "entropy", "categorical_psi"],
    "Model & Outcome Drift": ["score_psi", "target"],
}

COLUMN_RENAME_MAP = {
    # shared / identity columns
    "name": "Feature", "feature": "Feature", "label": "Status",
    # DQ: profile
    "type": "Data Type", "cardinality_count": "Unique Values", "missing_count": "Missing Count",
    "completeness_pct": "Completeness %", "uniqueness_pct": "Uniqueness %",
    "mean": "Mean", "std": "Std. Deviation", "min": "Min", "max": "Max",
    "skewness": "Skewness", "kurtosis": "Kurtosis",
    "q25": "25th Percentile", "q50": "Median", "q75": "75th Percentile", "n_outliers": "Outlier Count",
    # DQ: blockers / governance
    "rule": "Rule Triggered", "detail": "Details", "risk_type": "Risk Type",
    # DQ: health
    "completeness_score": "Completeness Score", "variance_score": "Variance Score",
    "governance_score": "Governance Score", "distribution_score": "Distribution Score",
    "health_score": "Health Score", "status": "Readiness Status",
    # Drift: schema
    "change_type": "Change Type", "dev_type": "Development Data Type", "mon_type": "Monitoring Data Type",
    # Drift: completeness
    "dev_completeness_pct": "Development Completeness %", "mon_completeness_pct": "Monitoring Completeness %",
    "delta_pp": "Change (Percentage Points)", "pattern": "Missingness Pattern",
    "dev_missing_pct": "Development Missing %", "mon_missing_pct": "Monitoring Missing %",
    # Drift: csi / categorical_psi
    "csi": "Stability Index (PSI)", "psi": "Population Stability Index (PSI)",
    # Drift: distribution
    "dev_mean": "Development Mean", "mon_mean": "Monitoring Mean",
    "dev_std": "Development Std. Deviation", "mon_std": "Monitoring Std. Deviation",
    "dev_min": "Development Min", "mon_min": "Monitoring Min",
    "dev_max": "Development Max", "mon_max": "Monitoring Max",
    "dev_skewness": "Development Skewness", "mon_skewness": "Monitoring Skewness",
    "cardinality_pct_change": "Unique-Value Count Change %", "std_drift_pct": "Std. Deviation Change %",
    "dev_cv": "Development Variability (CV)", "mon_cv": "Monitoring Variability (CV)",
    "cv_drift_pct": "Variability Change %", "kurtosis_delta": "Tail-Heaviness Change",
    "median_shift_iqr": "Median Shift (IQR-normalized)",
    # Drift: ks
    "ks_statistic": "KS Statistic",
    # Drift: score_psi
    "score_column": "Score Column",
    # Drift: target
    "target": "Target Column", "dev_event_rate_pct": "Development Event Rate %",
    "mon_event_rate_pct": "Monitoring Event Rate %",
    # Drift: entropy
    "dev_entropy": "Development Diversity", "mon_entropy": "Monitoring Diversity",
    "entropy_delta": "Diversity Change",
}

# Curated, grouped view of the cross-technique top-10 segmentation table
# (which has ~98 raw columns -- confidence intervals, p-value-adjusted
# variants, technique-internal fields like Cluster_ID/Leaf_ID/Tree_Idx, and
# several near-duplicate scores). Selects the columns that actually matter
# for a business reader, in this fixed order/grouping: identity -> population
# -> bad-rate/performance -> root cause -> overall severity. A raw column
# missing from a given run (e.g. no SHAP columns in the data) is skipped,
# not shown blank.
SEGMENTATION_TOP10_COLUMNS = [
    ("Overall_Rank", "Rank"),
    ("Technique", "Technique"),
    ("Segment_Definition", "Segment"),
    ("Discovered_By", "Discovered By"),

    ("Dev_Count", "Dev Count"),
    ("Mon_Count", "Mon Count"),
    ("Dev_Pct", "Dev %"),
    ("Mon_Pct", "Mon %"),
    ("Dev_Exposure_Pct", "Dev Exposure %"),
    ("Mon_Exposure_Pct", "Mon Exposure %"),
    ("Exposure_Drift", "Exposure Drift"),

    ("Dev_BR", "Dev Bad Rate"),
    ("Mon_BR", "Mon Bad Rate"),
    ("Delta_BR", "Delta Bad Rate"),
    ("Dev_AUC", "Dev AUC"),
    ("Mon_AUC", "Mon AUC"),
    ("Delta_AUC", "Delta AUC"),
    ("Dev_Gini", "Dev Gini"),
    ("Mon_Gini", "Mon Gini"),
    ("Delta_Gini", "Delta Gini"),

    ("Root_Cause_Feature", "Root Cause Feature"),
    ("Root_Cause_PSI", "Root Cause PSI"),
    ("Root_Cause_Score", "Root Cause Score"),
    ("Top_SHAP_Feature", "Top SHAP Feature"),
    ("Top_SHAP_PSI", "Top SHAP PSI"),

    ("PSI", "Segment PSI"),
    ("Severity_Score", "Severity Score"),
    ("Business_Impact_Score", "Business Impact Score"),
    ("Calibration_Drift", "Calibration Drift"),
    ("Statistically_Significant", "Statistically Significant"),
]
