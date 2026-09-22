"""
tools/data_drift_tool.py
Data Drift Tool — formats an already-computed drift result (from
sas_macros.dq_drift_python_translation.main_wrapper / drift_calc_wrapper)
into an LLM-readable text block. Does no computation of its own; wraps the
Utility's output for interpretability, per the Agent/Tools/Utilities pattern.
"""

import pandas as pd

from utils.display_labels import SECTION_LABELS as _SECTION_LABELS

# score_psi/target are dicts, not DataFrames, so they're handled separately
# below and don't need a section-label lookup for the DataFrame loop.
_DATAFRAME_SECTION_KEYS = [
    "schema", "completeness", "csi", "distribution", "ks", "entropy", "categorical_psi"
]


def build_context(drift: dict | None) -> str:
    if not drift:
        return ""

    parts = []

    for key in _DATAFRAME_SECTION_KEYS:
        value = drift.get(key)
        if isinstance(value, pd.DataFrame) and not value.empty:
            parts.append(f"=== Drift: {_SECTION_LABELS[key]} ===\n{value.to_string(index=False)}")

    score_psi = drift.get("score_psi")
    if isinstance(score_psi, dict) and score_psi:
        parts.append(
            f"=== Drift: {_SECTION_LABELS['score_psi']} ===\n"
            f"Score column: {score_psi.get('score_column')} | "
            f"PSI: {score_psi.get('psi')} | Label: {score_psi.get('label')}"
        )

    target = drift.get("target")
    if isinstance(target, dict) and target:
        parts.append(
            f"=== Drift: {_SECTION_LABELS['target']} ===\n"
            f"Target: {target.get('target')} | "
            f"Dev event rate: {target.get('dev_event_rate_pct')}% | "
            f"Mon event rate: {target.get('mon_event_rate_pct')}% | "
            f"Delta: {target.get('delta_pp')}pp | Label: {target.get('label')}"
        )

    return "\n\n".join(parts)
