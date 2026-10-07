import time
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from app.gemini import call_gemini


# ---------------------------------------------------------
# Jinja2
# ---------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent.parent

TEMPLATE_DIR = BASE_DIR / "prompts"


jinja = Environment(
    loader=FileSystemLoader(str(TEMPLATE_DIR)),
    undefined=StrictUndefined,
    autoescape=False,
    trim_blocks=True,
    lstrip_blocks=True,
)


def render(template_name: str, **kwargs) -> str:

    template = jinja.get_template(template_name)

    return template.render(**kwargs).strip()


# ---------------------------------------------------------
# Node execution
# ---------------------------------------------------------

def run_node(
    name: str,
    template_name: str,
    *,
    max_output_tokens: int = 500,
    **template_data,
) -> dict:

    print(f"[DAG] Starting: {name}")

    started = time.monotonic()

    prompt = render(
        template_name,
        **template_data,
    )

    result = call_gemini(
        prompt,
        max_output_tokens=max_output_tokens,
        temperature=0.2,
    )

    elapsed = time.monotonic() - started

    result["elapsed_seconds"] = round(
        elapsed,
        2,
    )

    print(
        f"[DAG] Finished: {name} "
        f"model={result['model']} "
        f"time={elapsed:.2f}s "
        f"input={result['input_tokens']} "
        f"output={result['output_tokens']} "
        f"total={result['total_tokens']}"
    )

    return result


# ---------------------------------------------------------
# DAG
# ---------------------------------------------------------

def run_dag(user_prompt: str) -> dict:

    dag_started = time.monotonic()

    print("=" * 50)
    print(
        f"[DAG] Starting request: "
        f"{user_prompt}"
    )
    print("=" * 50)

    # -----------------------------------------------------
    # Planner
    # -----------------------------------------------------

    planner = run_node(
        "planner",
        "planner.j2",
        prompt=user_prompt,
        max_output_tokens=350,
    )

    # -----------------------------------------------------
    # Research
    # -----------------------------------------------------

    research = run_node(
        "research",
        "research.j2",
        prompt=user_prompt,
        planner=planner["text"],
        max_output_tokens=450,
    )

    # -----------------------------------------------------
    # Analysis
    # -----------------------------------------------------

    analysis = run_node(
        "analysis",
        "analysis.j2",
        prompt=user_prompt,
        planner=planner["text"],
        research=research["text"],
        max_output_tokens=400,
    )

    # -----------------------------------------------------
    # Review
    # -----------------------------------------------------

    review = run_node(
        "review",
        "review.j2",
        prompt=user_prompt,
        research=research["text"],
        analysis=analysis["text"],
        max_output_tokens=300,
    )

    # -----------------------------------------------------
    # Final
    # -----------------------------------------------------

    final = run_node(
        "final",
        "final.j2",
        prompt=user_prompt,
        planner=planner["text"],
        research=research["text"],
        analysis=analysis["text"],
        review=review["text"],
        max_output_tokens=1600,
    )

    nodes = {
        "planner": planner,
        "research": research,
        "analysis": analysis,
        "review": review,
        "final": final,
    }

    # -----------------------------------------------------
    # Aggregate usage
    # -----------------------------------------------------

    input_tokens = sum(
        node["input_tokens"]
        for node in nodes.values()
    )

    output_tokens = sum(
        node["output_tokens"]
        for node in nodes.values()
    )

    reported_total_tokens = sum(
        node["total_tokens"]
        for node in nodes.values()
    )

    total_time = time.monotonic() - dag_started

    print("=" * 50)
    print("[DAG] Request completed")
    print(
        f"[DAG] Total time: "
        f"{total_time:.2f}s"
    )
    print(
        f"[DAG] Total input tokens: "
        f"{input_tokens}"
    )
    print(
        f"[DAG] Total output tokens: "
        f"{output_tokens}"
    )
    print(
        f"[DAG] Total reported tokens: "
        f"{reported_total_tokens}"
    )
    print("=" * 50)

    return {
        "answer": final["text"],

        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,

            # This is the sum of Google's reported
            # total_token_count values.
            "total_tokens": (
                input_tokens +
                output_tokens
            ),

            "reported_total_tokens": (
                reported_total_tokens
            ),

            "nodes": nodes,
        },

        "nodes": nodes,
    }


