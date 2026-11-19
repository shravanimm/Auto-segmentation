"""
gen_dictionary.py - generates autoseg_ucmacros/seg_metric_dictionary.sas.
Edit the list D below (column, label, meaning) and re-run:  python sas_macros/parity/gen_dictionary.py
Text must not contain the characters & % ; or double quotes (they would break the SAS code).
"""
import os, re

D = [
    # ---- identity / explanation
    ("Technique", "Technique", "Which technique discovered the segment or produced the run-log row"),
    ("Rank", "Rank within technique", "Position after ranking: statistically significant segments first then by Severity_Score. Comparable only within one technique"),
    ("Segment_Definition", "Segment definition", "Readable rule that defines the segment. Cut-offs are rounded to 2 decimals for display - the exact values are in the rules table"),
    ("Segment_Summary", "Plain-English summary", "One paragraph: size of the segment in development vs monitoring and how Gini KS and default rate moved and the feature that drifted most"),
    ("Segment_Where_Clause", "Executable SAS WHERE clause", "The rule as a SAS WHERE expression with exact cut-offs. Apply with WHERE= to select the segment rows"),
    ("Membership_Type", "How membership is decided", "EXACT_RULE: a row is in the segment exactly when it satisfies the rule. NEAREST_CENTROID: K-Means membership is the nearest cluster centre and the rule only describes it"),
    ("Membership_Note", "Missing-value treatment", "How missing values of numeric features are treated for this technique"),
    ("cand_id", "Candidate id", "Internal candidate number - joins the segments rules and feature_psi tables"),
    # ---- size / population
    ("Dev_Count", "Rows in dev", "Number of development rows inside the segment"),
    ("Mon_Count", "Rows in monitoring", "Number of monitoring rows inside the segment"),
    ("Dev_Pct", "Share of dev population", "Dev_Count divided by all development rows"),
    ("Mon_Pct", "Share of monitoring population", "Mon_Count divided by all monitoring rows"),
    ("x_dev", "Defaults in dev", "Number of defaults (events) in the segment - development"),
    ("x_mon", "Defaults in monitoring", "Number of defaults (events) in the segment - monitoring"),
    ("PSI", "PSI (segment size or feature drift)", "In the segments table: population stability index of the segment size = (Mon_Pct - Dev_Pct) x ln(Mon_Pct / Dev_Pct). In the feature_psi table: PSI of that feature inside the segment. Below 0.10 stable. 0.10 to 0.25 moderate shift. Above 0.25 significant shift"),
    ("PSI_Interpretation", "PSI reading", "Stable / Moderate Drift / Significant Drift according to PSI"),
    # ---- default rate
    ("Dev_BR", "Default rate dev", "Defaults divided by rows in development"),
    ("Mon_BR", "Default rate monitoring", "Defaults divided by rows in monitoring"),
    ("Delta_BR", "Default rate change", "Mon_BR minus Dev_BR. Positive means more defaults than at development"),
    ("br_pvalue", "p-value default rate change", "Two-sided z-test p-value that the dev and monitoring default rates are equal (small = real change)"),
    ("BadRate_pvalue_adj", "Adjusted p-value default rate", "br_pvalue after Benjamini-Hochberg correction for the many segments tested"),
    # ---- model performance
    ("Dev_AUC", "AUC dev", "Area under the ROC curve of the model score inside the segment - development"),
    ("Mon_AUC", "AUC monitoring", "Area under the ROC curve inside the segment - monitoring"),
    ("Delta_AUC", "AUC change", "Mon_AUC minus Dev_AUC. Negative means the model separates defaults worse"),
    ("Dev_Gini", "Gini dev", "2 x AUC - 1 in development"),
    ("Mon_Gini", "Gini monitoring", "2 x AUC - 1 in monitoring"),
    ("Delta_Gini", "Gini change", "Mon_Gini minus Dev_Gini. Negative means deterioration"),
    ("Dev_KS", "KS dev", "Largest gap between the cumulative score distributions of defaults and non-defaults - development"),
    ("Mon_KS", "KS monitoring", "Same measure in monitoring"),
    ("Delta_KS", "KS change", "Mon_KS minus Dev_KS. Negative means deterioration"),
    ("score_shift_pvalue", "p-value score distribution shift", "Two-sample Kolmogorov-Smirnov p-value that the model score distribution differs between development and monitoring inside the segment"),
    ("ScoreShift_pvalue_adj", "Adjusted p-value score shift", "score_shift_pvalue after Benjamini-Hochberg correction"),
    ("Calibration_Drift", "Calibration drift (A/E shift)", "Actual-to-expected default ratio in monitoring minus the same ratio in development. Expected defaults = sum of model scores"),
    # ---- exposure
    ("Dev_EAD", "Exposure dev", "Sum of the exposure column inside the segment - development"),
    ("Mon_EAD", "Exposure monitoring", "Sum of the exposure column inside the segment - monitoring"),
    ("Dev_Exposure_Pct", "Share of dev exposure", "Segment exposure divided by total development exposure"),
    ("Mon_Exposure_Pct", "Share of monitoring exposure", "Segment exposure divided by total monitoring exposure"),
    ("Exposure_Drift", "Exposure share change", "Mon_Exposure_Pct minus Dev_Exposure_Pct"),
    # ---- root cause
    ("mean_feature_psi", "Average feature drift inside segment", "Mean PSI over all features comparing the segment rows of development with the segment rows of monitoring"),
    ("Root_Cause_Feature", "Main drifting feature", "Feature with the highest PSI inside the segment - a candidate driver and not proof of cause. For Feature Binning it is the feature that defines the bin"),
    ("Root_Cause_PSI", "PSI of main drifting feature", "PSI of Root_Cause_Feature inside the segment. For Feature Binning the size-shift PSI of the bin"),
    ("mean_shap_shift", "Average SHAP shift", "Mean absolute change of the average SHAP value across SHAP columns inside the segment"),
    # ---- scores
    ("Statistically_Significant", "Statistically significant", "1 when the adjusted default-rate p-value or the adjusted score-shift p-value is at or below alpha"),
    ("Business_Impact_Score", "Business impact", "(Mon_Pct x Mon_Exposure_Pct) x (1 + PSI + Gini drop). Used to choose between parameter settings"),
    ("SIS_Raw", "Segment Impact Score", "AUC drop x exposure share x Mon_Pct x Confidence_Score"),
    ("DIS_Raw", "Drift Impact Score", "(Mon_Pct - Dev_Pct) x AUC drop x exposure share x (1 + mean_feature_psi) floored at 0"),
    ("DIS_Symmetric", "Drift Impact Score symmetric", "Like DIS_Raw but with the absolute population change so shrinking segments also count"),
    ("Confidence_Score", "Sample-size confidence", "Square root of (Mon_Count / 100) capped at 1"),
    ("Root_Cause_Score", "Root cause score", "0.35 x SIS + 0.30 x DIS + 0.20 x mean_feature_psi + 0.15 x mean_shap_shift each scaled 0 to 1 across the candidates of this run. Larger = more likely a main driver of the decline"),
    ("Severity_Score", "Severity score", "Root_Cause_Score x 20. Used for ranking inside one technique only"),
    ("Portfolio_Impact_Score", "Portfolio impact", "Mon_Pct x absolute Gini change"),
    ("Drift_Explanation", "Why it was flagged", "Automatic reasons: size shift Gini or KS drop significant default-rate shift or hidden concept drift"),
    # ---- technique specific
    ("Leaf_ID", "Tree node id", "Node number of the tree leaf the segment comes from"),
    ("Tree_Idx", "Tree number", "Which boosted tree the segment comes from"),
    ("Cluster_ID", "Cluster number", "K-Means cluster the segment comes from"),
    ("Rule_Precision", "Rule precision", "Share of rows matching the rule that really belong to the cluster"),
    ("Rule_Recall", "Rule recall", "Share of the cluster rows that match the rule"),
    # ---- feature binning
    ("Feature", "Feature", "Feature a bin or condition is built on (Feature Binning segments and the rules and feature_psi tables)"),
    ("Bin_Type", "Bin type", "numeric interval / categorical group / missing"),
    ("Significant", "Significant (bootstrap)", "1 when the smallest Benjamini-Hochberg adjusted bootstrap p-value is at or below the Feature Binning alpha"),
    ("Overall_Score", "Overall score", "Feature Binning ranking score (Root cause score x 20)"),
    ("Deterioration_Score", "Deterioration score", "Average of the scaled Gini KS AUC default-rate and ECE changes - tie-break and diagnostic"),
    ("Exposure_Pct", "Share of monitoring exposure", "Segment exposure share in monitoring"),
    ("Mon_Default_Count", "Defaults in monitoring", "Number of defaults in the bin - monitoring"),
    ("Dev_Calibration_Intercept", "Calibration intercept dev", "Intercept of a logistic regression of the target on the raw score - development"),
    ("Mon_Calibration_Intercept", "Calibration intercept monitoring", "Same - monitoring"),
    ("Delta_Calibration_Intercept", "Calibration intercept change", "Mon minus Dev intercept"),
    ("Dev_Calibration_Slope", "Calibration slope dev", "Slope of that regression - development"),
    ("Mon_Calibration_Slope", "Calibration slope monitoring", "Slope - monitoring"),
    ("Delta_Calibration_Slope", "Calibration slope change", "Mon minus Dev slope"),
    ("Dev_ECE", "Expected calibration error dev", "Weighted average gap between mean score and observed default rate across 10 score bins - development"),
    ("Mon_ECE", "Expected calibration error monitoring", "Same - monitoring"),
    ("Delta_ECE", "ECE change", "Mon_ECE minus Dev_ECE"),
    ("gini_p", "Bootstrap p-value Gini", "Bootstrap p-value for the Gini change"),
    ("ks_p", "Bootstrap p-value KS", "Bootstrap p-value for the KS change"),
    ("auc_p", "Bootstrap p-value AUC", "Bootstrap p-value for the AUC change"),
    ("br_p", "Bootstrap p-value default rate", "Bootstrap p-value for the default-rate change"),
    ("ece_p", "Bootstrap p-value ECE", "Bootstrap p-value for the ECE change"),
    ("min_p_adj", "Smallest adjusted p-value", "Smallest Benjamini-Hochberg adjusted bootstrap p-value"),
    # ---- rules table
    ("ptype", "Condition type", "N numeric interval - C feature equals value - X feature not equal value - M feature is missing"),
    ("lower", "Lower cut-off", "Lower bound of a numeric interval (exact value)"),
    ("upper", "Upper cut-off", "Upper bound of a numeric interval (exact value)"),
    ("lo_inf", "No lower bound", "1 when the interval is open on the low side"),
    ("hi_inf", "No upper bound", "1 when the interval is open on the high side"),
    ("value", "Category value", "Category for C and X conditions"),
    ("label", "Condition text", "Readable text of the condition (rounded)"),
    ("condition", "Condition (exact)", "The condition with exact cut-offs as SAS WHERE text"),
    # ---- portfolio / cross
    ("Segment", "Segment", "Segment definition text"),
    ("Population_Pct", "Population share", "Share of the monitoring population"),
    ("Severity_PopulationXGini", "Portfolio severity", "Population share x absolute Gini change"),
    ("Overall_Rank", "Overall rank", "Rank across all techniques by Normalized_Root_Cause_Score"),
    ("Discovered_By", "Found by", "Every technique that independently found this same population"),
    ("Normalized_Root_Cause_Score", "Cross-technique score", "Root_Cause_Score scaled 0 to 1 over the pooled top segments of all techniques - the only score comparable across techniques"),
    # ---- schema table
    ("column_name", "Column", "Column name in the development table"),
    ("data_type", "Data type", "numeric or character"),
    ("role", "Role", "TARGET SCORE WEIGHT ID TIME SHAP FEATURE_NUMERIC FEATURE_CATEGORICAL or EXCLUDED"),
    ("reason", "Reason", "Why the column received this role"),
    ("source", "Source", "caller = given in the trigger. auto-detected = decided by the engine. default list = built-in exclusion"),
    ("n_distinct", "Distinct values", "Number of distinct non-missing values"),
    ("pct_missing", "Percent missing", "Share of missing values in development"),
    ("min_value", "Minimum", "Smallest value (numeric columns)"),
    ("max_value", "Maximum", "Largest value (numeric columns)"),
    ("leak_auc", "Leakage screen", "Single-feature absolute AUC minus 0.5 against the target (categories use their default rate). Values near 0 are normal - values near 0.5 mean the column predicts the target suspiciously well"),
    ("drift_auc", "Drift strength", "Absolute AUC minus 0.5 of the column for telling development rows from monitoring rows. Higher = the column drifted more"),
    ("feat_rank", "Feature rank", "Rank of the column by the larger of its drift and default strength. Only the top sg_cfg_max_features columns are searched"),
    # ---- trend analysis
    ("Period", "Period", "Monitoring period label (value of the period column)"),
    ("Period_Index", "Period number", "0-based chronological position of the period"),
    ("Periods_Appeared", "Periods appeared", "In how many periods the segment was among the worst segments of its technique"),
    ("Total_Periods", "Periods analysed", "Number of monitoring periods analysed"),
    ("Appeared_In", "Appeared in", "The periods in which the segment was among the worst"),
    ("Frequency", "Frequency", "Periods appeared divided by periods analysed"),
    ("Recency_Factor", "Recency", "0.5 to the power (periods since the last appearance divided by the half-life). 1 = appeared in the latest period"),
    ("Consistency_Score", "Consistency", "Longest run of consecutive periods the segment appeared in divided by periods analysed"),
    ("Trend_Impact_Score", "Trend impact score", "Weighted blend of Frequency Recency and Consistency (0.4 0.3 0.3 by default). 1 = worst every period and in the latest"),
    ("SIS_Trend", "SIS boosted by persistence", "SIS_Raw multiplied by (1 + trend weight x Trend_Impact_Score). Informational"),
    ("Root_Cause_Score_Trend", "Root-cause score with persistence", "The single-period root-cause blend recomputed over the recurring segments of one technique then boosted once by (1 + trend weight x Trend_Impact_Score) and capped at 1"),
    ("Severity_Score_Trend", "Severity with persistence", "Root_Cause_Score_Trend x 20. Comparable only within one technique"),
    ("Periods_Used", "Periods in the forecast", "Number of periods of history the forecast line is fitted on"),
    ("Last_Appeared_Period", "Last appeared in", "Latest period in which the segment was among the worst"),
    ("Current_Root_Cause_Score", "Current root-cause score", "Root_Cause_Score in the latest period the segment appeared"),
    ("Predicted_Next_Root_Cause_Score", "Forecast next score", "Straight-line projection of Root_Cause_Score one period ahead capped to 0 to 1"),
    ("Predicted_Next_Lower95", "Forecast lower 95 pct", "Lower end of the 95 percent prediction interval (needs 3 or more periods)"),
    ("Predicted_Next_Upper95", "Forecast upper 95 pct", "Upper end of the 95 percent prediction interval (needs 3 or more periods)"),
    ("Trend_Slope", "Trend slope", "Change of Root_Cause_Score per period. Positive = getting worse"),
    ("R_Squared", "R-squared", "How well a straight line fits the segment history (needs 3 or more periods)"),
    ("Trend_P_Value", "Trend p-value", "Probability of a slope this steep if there were no real trend (needs 3 or more periods). Small = real trend"),
    ("Months_To_Breach", "Periods to breach", "Whole periods until the projected score crosses the alert level. Reported only within the forecast horizon"),
    ("Confidence", "Forecast confidence", "Low with 2 periods of history and medium with 3 or more"),
    ("Early_Warning", "Early warning", "1 when the segment is worsening and projected to cross the alert level within the horizon"),
    # ---- parameter search / run config / log
    ("combo", "Combination number", "Order in which the parameter combination was tried"),
    ("parameters", "Parameters tried", "The parameter values of this combination"),
    ("objective_score", "Objective score", "Sum of Business_Impact_Score of the segments this combination returned. Higher wins"),
    ("rank_by_score", "Rank by objective", "1 = best combination"),
    ("selected", "Chosen", "1 for the combination whose results are reported"),
    ("selection_rule", "Selection rule", "How the winning combination was chosen"),
    ("setting", "Setting", "Name of the global setting"),
    ("description", "Description", "What the setting controls"),
    ("status", "Status", "OK ERROR or NOT_RUN"),
    ("message", "Message", "Details when a technique did not run"),
    ("seconds", "Run time (s)", "Seconds the technique took"),
    ("total_dev_n", "Development rows", "Rows in the development table"),
    ("total_mon_n", "Monitoring rows", "Rows in the monitoring table"),
    ("min_abs_count", "Minimum rows per segment", "Smallest allowed segment size (derived from the default rate)"),
    ("min_support", "Minimum share per segment", "Smallest allowed segment share"),
    ("candidates_evaluated", "Candidates evaluated", "Segments that passed the size and default-count gates and were scored"),
    ("candidates_returned", "Candidates returned", "Segments in the output table"),
]


def q(s):
    assert not re.search(r'[&%;"]', s), s
    return '"' + s + '"'


out = [
    "/* ============================================================================",
    "   seg_metric_dictionary.sas  -  GENERATED by parity/gen_dictionary.py (edit the list there).",
    "   Data dictionary for every output column: short label + plain meaning / formula.",
    "   seg_apply_labels uses it to attach SAS column labels to every output table so the",
    "   tables explain themselves wherever they are opened.",
    "   ============================================================================ */",
    "%macro seg_metric_dictionary(out=seg_metric_dictionary);",
    "    data &out;",
    "        length column_name $40 label $80 meaning $500;",
]
seen = set()
for c, l, m in D:
    assert c.lower() not in seen, c
    seen.add(c.lower())
    assert len(l) <= 80, (c, len(l))
    assert len(m) <= 500, (c, len(m))
    out.append(f"        column_name = {q(c)}; label = {q(l)}; meaning = {q(m)}; output;")
out += ["    run;", "%mend seg_metric_dictionary;", ""]
target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "autoseg_ucmacros", "seg_metric_dictionary.sas")
open(target, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print("dictionary entries:", len(D), "->", os.path.normpath(target))
