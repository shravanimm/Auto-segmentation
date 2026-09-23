"""
agents/model_rca_agent_agentic.py
Experimental v2 of the Model RCA Agent: real tool-calling instead of
model_rca_agent.py's "assemble everything, one LLM call" approach.

The question goes to the LLM first. The LLM decides which of the three
Tool contexts (DQ / DD / SEG) it actually needs, calls only those, and
writes its answer grounded in just what it asked for -- instead of always
seeing all three regardless of what was asked.

This is intentionally a separate module, not a rewrite of
model_rca_agent.py: that file (and its prompt, llm/prompts/rca_prompt.md)
is left completely untouched so the app can fall back to it at any time
-- see the toggle in streamlit_app.py's Home tab chat panel.

Underlying Tool outputs, DQ/DD/SEG math, and the Home tab checkboxes are
unchanged; only how the chat step picks which of those outputs to look at
is different.
"""

import re

from llm.llm_client import client, MODEL_DEPLOYMENT
from llm.prompt_builder import build_rca_agentic_system_prompt

# Deterministic floor under the model's tool-selection judgment: if the
# question contains one of these terms, that tool is included in the
# answer's context even if the model didn't choose to call it. This never
# removes a tool the model DID call -- it only adds ones a keyword match
# says shouldn't have been skipped. Calling/including a tool costs nothing
# here (it's a pre-computed string, not a recomputation), so this floor is
# one-directional: it can only make the answer see more, never less.
KEYWORD_RULES = {
    "get_data_quality_findings": [
        r"\bmissing\b", r"\bduplicate", r"\bnull\b", r"\boutlier",
        r"\bpii\b", r"\bleakage\b", r"\bgovernance\b", r"\bidentifier\b",
        r"\breadiness\b", r"\bdata quality\b", r"\bdq\b", r"\busable\b",
        r"\bcompleteness\b",
    ],
    "get_data_drift_findings": [
        r"\bdrift\b", r"\bpsi\b", r"\bcsi\b", r"\bks\b", r"\bstab(le|ility)\b",
        r"\bshift(ed)?\b", r"\bschema change", r"\bdistribution\b",
        r"\bentropy\b", r"\bpopulation change", r"\bdd\b",
    ],
    "get_segmentation_findings": [
        r"\bsegment", r"\broot cause\b", r"\btechnique\b", r"\bworst\b",
        r"\bslicer\b", r"\bseg\b", r"\bgini\b",
    ],
}


def _keyword_forced_tools(question: str) -> set:
    q = question.lower()
    return {
        name for name, patterns in KEYWORD_RULES.items()
        if any(re.search(p, q) for p in patterns)
    }


TOOL_LABELS = {
    "get_data_quality_findings": "DQ",
    "get_data_drift_findings": "DD",
    "get_segmentation_findings": "SEG",
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_data_quality_findings",
            "description": (
                "Returns the computed Data Quality (DQ) results for this dataset: "
                "Dataset Readiness Score, per-column health scores, blocked columns, "
                "and governance flags. Call this for questions about missing values, "
                "duplicates, data types, outliers, PII/leakage risk, or whether the "
                "data is usable. Returns a message saying DQ wasn't run if it wasn't."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_data_drift_findings",
            "description": (
                "Returns the computed Data Drift (DD) results for this dataset: "
                "schema/structural changes, missing-data drift, PSI/CSI feature "
                "stability, distribution shape changes, KS statistic, category "
                "diversity and mix drift, and model prediction / actual outcome "
                "drift. Call this for questions about drift, stability, distribution "
                "shift, or whether the population/model behavior changed between "
                "periods. Returns a message saying DD wasn't run if it wasn't."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_segmentation_findings",
            "description": (
                "Returns the computed Segmentation (SEG) results for this dataset: "
                "per-technique scores (Overall_Score_100, Max_PSI, Max_Gini_Drop, "
                "Root_Cause_Feature), a cross-technique top-10 worst-segment ranking, "
                "and an executive summary. Call this for questions about which "
                "segment is worst, which technique flagged what, or the root-cause "
                "feature behind a segment. Returns a message saying SEG wasn't run "
                "if it wasn't."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
]

_NOT_RUN = {
    "get_data_quality_findings": "Data Quality was not run for this dataset -- no DQ results are available.",
    "get_data_drift_findings": "Data Drift was not run for this dataset -- no DD results are available.",
    "get_segmentation_findings": "Segmentation was not run for this dataset -- no SEG results are available.",
}


def answer(question: str, dq_context: str, drift_context: str, seg_context: str,
           glance_context: str = "") -> tuple[str, list[str]]:
    """Same inputs as agents.model_rca_agent.answer(), but the LLM chooses
    which context(s) to look at instead of receiving all of them upfront.

    Returns (answer_text, tool_labels_used) -- the label list is for the UI
    to show which tools the model actually invoked, so answers stay
    auditable during rollout."""

    tool_results = {
        "get_data_quality_findings": dq_context or _NOT_RUN["get_data_quality_findings"],
        "get_data_drift_findings": drift_context or _NOT_RUN["get_data_drift_findings"],
        "get_segmentation_findings": seg_context or _NOT_RUN["get_segmentation_findings"],
    }

    messages = [{"role": "system", "content": build_rca_agentic_system_prompt()}]
    if glance_context:
        messages.append({
            "role": "system",
            "content": (
                "Dataset overview, for orientation only -- this is not a substitute "
                "for calling the DQ/DD/SEG tools to get taggable findings:\n"
                + glance_context
            ),
        })
    messages.append({"role": "user", "content": question})

    first = client.chat.completions.create(
        model=MODEL_DEPLOYMENT,
        messages=messages,
        tools=TOOLS,
        tool_choice="required",
    )
    msg = first.choices[0].message

    tools_used: list[str] = []
    if msg.tool_calls:
        messages.append(msg)
        called_names = set()
        for call in msg.tool_calls:
            name = call.function.name
            called_names.add(name)
            result = tool_results.get(name, f"Unknown tool: {name}")
            tools_used.append(TOOL_LABELS.get(name, name))
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": result,
            })

        forced = _keyword_forced_tools(question) - called_names
        for name in forced:
            tools_used.append(f"{TOOL_LABELS.get(name, name)} (auto)")
            messages.append({
                "role": "system",
                "content": (
                    f"Additional required context -- the question matched keywords for "
                    f"{TOOL_LABELS.get(name, name)}, so include it even though it wasn't "
                    f"explicitly called:\n{tool_results[name]}"
                ),
            })

        messages.append({
            "role": "system",
            "content": "Now write your final answer, tagging every line per the MANDATORY FORMAT RULE above.",
        })
        second = client.chat.completions.create(model=MODEL_DEPLOYMENT, messages=messages)
        final_text = second.choices[0].message.content
    else:
        final_text = msg.content

    return final_text, tools_used
