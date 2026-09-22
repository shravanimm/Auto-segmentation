from functools import lru_cache
from pathlib import Path

# Prompt text lives in llm/prompts/*.md, not inline in this file, so the
# wording can be reviewed/edited without touching Python. Each file is a
# str.format() template -- the {placeholders} below match this module's
# call sites exactly, so behavior/output is unchanged from the previous
# inline f-strings.
_PROMPTS_DIR = Path(__file__).parent / "prompts"


@lru_cache(maxsize=None)
def _load_template(filename: str) -> str:
    raw = (_PROMPTS_DIR / filename).read_text(encoding="utf-8").strip()
    # The original f-string prompts opened and closed with a blank line
    # (f"""\n...\n"""); re-adding that here keeps the generated prompt
    # text identical to before, now that the body itself comes from a
    # cleanly-formatted .md file instead.
    return f"\n{raw}\n"


def build_qa_prompt(question: str, context_text: str) -> str:

    return _load_template("qa_prompt_Tab2.md").format(context_text=context_text, question=question)


def build_rca_prompt(question: str, context_text: str) -> str:

    return _load_template("rca_prompt.md").format(context_text=context_text, question=question)


def build_segment_prompt(segment_info: dict) -> str:

    return _load_template("segment_prompt.md").format(
        segment_definition=segment_info.get('Segment_Definition'),
        psi=segment_info.get('PSI'),
        delta_gini=segment_info.get('Delta_Gini'),
        delta_br=segment_info.get('Delta_BR'),
        root_cause_feature=segment_info.get('Root_Cause_Feature'),
    )
