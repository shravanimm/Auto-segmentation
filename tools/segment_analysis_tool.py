"""
tools/segment_analysis_tool.py
Segment Analysis Tool — formats an already-computed segmentation benchmark
result (from compare_segmentation_techniques.benchmark_all_techniques) into
an LLM-readable text block. Does no computation of its own; wraps the
Utility's output for interpretability, per the Agent/Tools/Utilities pattern.
"""

import pandas as pd

_SUMMARY_COLS = [
    "Technique", "Overall_Score_100", "Max_PSI", "Max_Gini_Drop",
    "Root_Cause_Feature", "Root_Cause_Score",
]
_TOP10_COLS = [
    "Overall_Rank", "Technique", "Segment_Definition", "Normalized_Root_Cause_Score",
]


def build_context(summary_df: pd.DataFrame | None,
                   combined_segments_df: pd.DataFrame | None,
                   cross_top10_df: pd.DataFrame | None,
                   cross_exec_summary_df: pd.DataFrame | None) -> str:
    if summary_df is None or summary_df.empty:
        return ""

    parts = []

    cols = [c for c in _SUMMARY_COLS if c in summary_df.columns]
    parts.append("=== Segmentation: Per-Technique Summary ===\n" + summary_df[cols].to_string(index=False))

    if isinstance(cross_top10_df, pd.DataFrame) and not cross_top10_df.empty:
        cols = [c for c in _TOP10_COLS if c in cross_top10_df.columns]
        parts.append("=== Segmentation: Cross-Technique Top-10 Root-Cause Segments ===\n"
                      + cross_top10_df[cols].to_string(index=False))

    if isinstance(cross_exec_summary_df, pd.DataFrame) and not cross_exec_summary_df.empty:
        parts.append("=== Segmentation: Executive Summary ===\n"
                      + cross_exec_summary_df.to_string(index=False))

    return "\n\n".join(parts)
