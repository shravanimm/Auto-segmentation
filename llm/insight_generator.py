from llm.llm_client import client, MODEL_DEPLOYMENT
from llm.prompt_builder import build_segment_prompt, build_qa_prompt, build_rca_prompt


def generate_insight(segment_info):

    prompt = build_segment_prompt(segment_info)

    response = client.chat.completions.create(
        model=MODEL_DEPLOYMENT,
        messages=[
            {
                "role": "user",
                "content": prompt
            }
        ]
    )

    return response.choices[0].message.content


def answer_data_question(question: str, context_text: str) -> str:
    """Free-form Q&A over whatever run results are currently on screen.
    Same client/call shape as generate_insight -- just a different prompt
    (a question + a data context, instead of one fixed segment template)."""

    prompt = build_qa_prompt(question, context_text)

    response = client.chat.completions.create(
        model=MODEL_DEPLOYMENT,
        messages=[
            {
                "role": "user",
                "content": prompt
            }
        ]
    )

    return response.choices[0].message.content


def answer_rca_question(question: str, context_text: str) -> str:
    """Model RCA Agent's LLM call -- same client/call shape as
    answer_data_question, using the RCA-persona prompt instead so this stays
    independent of Tab 2's Q&A prompt/behavior."""

    prompt = build_rca_prompt(question, context_text)

    response = client.chat.completions.create(
        model=MODEL_DEPLOYMENT,
        messages=[
            {
                "role": "user",
                "content": prompt
            }
        ]
    )

    return response.choices[0].message.content