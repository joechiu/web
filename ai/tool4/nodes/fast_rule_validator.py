from promptflow.core import tool
from nodes.tools import *

def handle_upstream_status(status):
    if status == "C":
        return func.build_response(
            outcome="S",
            route=msg.fast.skip,
            skipped=True,
            upstream=status,
        )

    if status == "E":
        return func.build_response(
            outcome="E",
            route=msg.fast.escalate,
            hard_stop=True,
            upstream=status,
        )

    if status == "B":
        return func.build_response(
            outcome="B",
            route=msg.fast.block,
            hard_stop=True,
            upstream=status,
        )

    if status == "R":
        return func.build_response(
            outcome="R",
            route=msg.fast.review,
            hard_stop=True,
            upstream=status,
        )

    return None

def validate_structure(draft, mandatory_structure):
    draft_lower = draft.lower()
    reviews = []

    for section in mandatory_structure:
        section = str(section).strip()

        if section and section.lower() not in draft_lower:
            reviews.append({
                "rule": "MANDATORY_STRUCTURE",
                "severity": "REVIEW REQUIRED",
                "missing": [section],
            })

    return reviews

def validate_length(draft, mandatory_structure, enable_length):
    if (
        enable_length
        and not draft.strip()
        and not mandatory_structure
    ):
        return [{
            "rule": "EMPTY_CONTENT",
            "severity": "BLOCK",
            "actual_length": 0,
            "minimum": 1,
        }]

    return []

def resolve_outcome(reviews, findings, warnings):
    if reviews: return "R"
    if findings: return "B"
    if warnings: return "W"
    return "P"

@tool
def main(
    draft_output: str,
    mandatory_structure: list = None,
    preview_status: str = "",
    enable_length: bool = True,
) -> dict:

    t = Timer()

    draft = str(draft_output or "")
    mandatory_structure = mandatory_structure or []

    incoming_status = func.normalize_outcome(
        preview_status,
        default="",
    )

    # Respect the upstream human-review decision.
    upstream_response = handle_upstream_status(
        incoming_status
    )

    if upstream_response is not None:
        return upstream_response

    # Run deterministic fast checks.
    findings = validate_length(
        draft,
        mandatory_structure,
        enable_length,
    )

    reviews = validate_structure(
        draft,
        mandatory_structure,
    )

    warnings = []

    outcome = resolve_outcome(
        reviews,
        findings,
        warnings,
    )

    return func.build_response(
        outcome=outcome,
        reason="Fast rule validation completed.",
        findings=findings,
        warnings=warnings,
        hard_stop=outcome == "B",
        upstream=incoming_status,
        execution_time=t.stop(),
    )


