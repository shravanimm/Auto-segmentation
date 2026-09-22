"""
agents/model_rca_agent.py
Model RCA (Root Cause Analysis) Agent — the orchestrator for the Home tab's
conversational AI. Assembles whichever Tool contexts are available (Data
Quality / Data Drift / Segment Analysis) into one combined context, then asks
the LLM to answer the user's question grounded in that already-computed data.

v1 is a single assembled-context + single LLM call, not multi-step
function-calling: the checkboxes on the Home tab already say exactly which
analyses ran, so there is no "which tool should I call" decision left for an
agent to make. This module has no Streamlit dependency so it can be tested
independently of the UI.
"""

from llm.insight_generator import answer_rca_question


def build_combined_context(dq_context: str, drift_context: str, seg_context: str,
                            glance_context: str = "") -> str:
    parts = [c for c in (dq_context, drift_context, seg_context, glance_context) if c]
    return "\n\n".join(parts)


def answer(question: str, dq_context: str, drift_context: str, seg_context: str,
           glance_context: str = "") -> str:
    combined_context = build_combined_context(dq_context, drift_context, seg_context, glance_context)
    return answer_rca_question(question, combined_context)
