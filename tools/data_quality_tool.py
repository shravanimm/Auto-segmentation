"""
tools/data_quality_tool.py
Data Quality Tool — formats an already-computed DQ result (from
sas_macros.dq_drift_python_translation.main_wrapper) into an LLM-readable
text block. Does no computation of its own; wraps the Utility's output for
interpretability, per the Agent/Tools/Utilities pattern.
"""

import pandas as pd


def _format_one(dq_result: dict, label: str) -> str:
    lines = [f"=== Data Quality ({label}) ==="]

    readiness = dq_result.get("readiness_score")
    if readiness is not None:
        lines.append(f"Dataset Readiness Score: {readiness}/100")

    health = dq_result.get("health")
    if isinstance(health, pd.DataFrame) and not health.empty:
        lines.append("\nColumn health scores:")
        lines.append(health.to_string(index=False))

    blockers = dq_result.get("blockers")
    if isinstance(blockers, pd.DataFrame) and not blockers.empty:
        lines.append("\nBlocked columns (drop before modeling):")
        lines.append(blockers.to_string(index=False))

    governance = dq_result.get("governance")
    if isinstance(governance, pd.DataFrame) and not governance.empty:
        lines.append("\nGovernance flags (identifier / leakage / privacy):")
        lines.append(governance.to_string(index=False))

    return "\n".join(lines)


def build_context(dq_dev: dict | None, dq_mon: dict | None = None) -> str:
    if not dq_dev:
        return ""

    parts = [_format_one(dq_dev, "Development")]
    if dq_mon:
        parts.append(_format_one(dq_mon, "Monitoring"))

    return "\n\n".join(parts)
