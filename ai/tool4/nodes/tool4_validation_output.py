# tool4_validation_output.py

from promptflow.core import tool
from nodes.tools import *

def quality_scores(llm_result):
    quality = func.safe_dict(
        llm_result.get("quality_scores")
    )

    if not quality:
        return {}

    scores = {}

    for key in conf.QUALITY_KEYS:
        try:
            score = int(
                quality.get(key, 0)
            )
        except (TypeError, ValueError):
            score = 0

        score = max(
            0,
            min(4, score),
        )

        scores[key] = score
        scores[f"{key}_percentage"] = round(
            score / 4 * 100,
            2,
        )

    total = sum(
        scores[key]
        for key in conf.QUALITY_KEYS
    )

    maximum = len(conf.QUALITY_KEYS) * 4

    scores["total_score"] = total
    scores["maximum_score"] = maximum
    scores["percentage"] = (
        round(
            total / maximum * 100,
            2,
        )
        if maximum
        else 0.0
    )

    return scores


def get_status(decision, awaiting_pv=False):
    if awaiting_pv:
        return "Awaiting for Pre Validation"

    status_map = {
        "B": "BLOCKED",
        "E": "ESCALATED",
        "P": "Awaiting for approval",
        "W": "Awaiting for approval",
        "R": "Awaiting for approval",
    }

    return status_map.get(
        decision,
        "VALIDATION_COMPLETE",
    )


def get_node_outcomes(
    inputs,
    fast,
    configurable,
    llm,
    decision,
):
    return {
        "inputs_validator": func.normalize_outcome(
            inputs.get("outcome"),
            default="N",
        ),
        "fast_rule_validator": func.normalize_outcome(
            fast.get("outcome"),
            default="S",
        ),
        "configurable_rules": func.normalize_outcome(
            configurable.get("outcome"),
            default="S",
        ),
        "unified_llm_validator": func.normalize_outcome(
            llm.get("outcome"),
            default="S",
        ),
        "decision_router": decision,
    }


def get_outcome_trace(node_outcomes):
    return {
        "outcomes": list(
            node_outcomes.values()
        ),
        "node_outcomes": node_outcomes,
        "node_outcome_labels": {
            name: conf.OUTCOME_LABELS.get(
                outcome,
                outcome,
            )
            for name, outcome
            in node_outcomes.items()
        },
        "final_outcome": node_outcomes[
            "decision_router"
        ],
        "final_label": conf.OUTCOME_LABELS.get(
            node_outcomes["decision_router"],
            node_outcomes["decision_router"],
        ),
    }


def get_warnings(configurable, llm):
    warnings = func.safe_list(
        configurable.get("warnings")
    )

    warnings.extend(
        finding
        for finding in func.safe_list(
            llm.get("findings")
        )
        if (
            isinstance(finding, dict)
            and str(
                finding.get("severity", "")
            ).upper() == "WARNING"
        )
    )

    return warnings


@tool
def main(
    decision_result,
    configurable_result,
    llm_result,
    inputs_result=None,
    fast_result=None,
    draft_output: str = "",
) -> dict:

    t = Timer()

    decision_res = func.safe_dict(
        decision_result
    )
    configurable_res = func.safe_dict(
        configurable_result
    )
    llm_res = func.safe_dict(
        llm_result
    )
    inputs_res = func.safe_dict(
        inputs_result
    )
    fast_res = func.safe_dict(
        fast_result
    )

    decision = func.normalize_outcome(
        decision_res.get("decision"),
        "R",
    )

    preview_outcome = func.normalize_outcome(
        inputs_res.get("outcome"),
        "N",
    )

    fast_outcome = func.normalize_outcome(
        fast_res.get("outcome"),
        "S",
    )

    configurable_outcome = func.normalize_outcome(
        configurable_res.get("outcome"),
        "S",
    )

    llm_outcome = func.normalize_outcome(
        llm_res.get("outcome"),
        "S",
    )

    awaiting_pv = bool(
        decision_res.get(
            "awaiting_pre_validation",
            False,
        )
    )

    node_outcomes = get_node_outcomes(
        inputs_res,
        fast_res,
        configurable_res,
        llm_res,
        decision,
    )

    outcome_trace = get_outcome_trace(
        node_outcomes
    )

    fast_findings = func.safe_list(
        fast_res.get("findings")
    )

    configurable_findings = func.safe_list(
        configurable_res.get("findings")
    )

    llm_findings = func.safe_list(
        llm_res.get("findings")
    )

    warnings = get_warnings(
        configurable_res,
        llm_res,
    )

    scores = quality_scores(
        llm_res
    )

    proposed_draft = str(
        llm_res.get(
            "proposed_final_draft"
        )
        or ""
    )

    final_permitted_draft = (
        proposed_draft or draft_output
        if decision in {"P", "W", "R"}
        else None
    )

    compliance = func.safe_dict(
        llm_res.get("compliance")
    )

    grounding = func.safe_dict(
        llm_res.get("grounding")
    )

    return {
        "decision": decision,
        "validation_result": {
            "decision": decision,
            "fast_outcome": fast_outcome,
            "configurable_outcome": configurable_outcome,
            "llm_outcome": llm_outcome,
        },
        "rule_findings": (
            fast_findings
            + configurable_findings
        ),
        "llm_validation_findings": llm_findings,
        "quality_scores": scores,
        "quality_percentage": scores.get(
            "percentage"
        ),
        "compliance_findings": compliance,
        "evidence_grounding_findings": grounding,
        "warnings": warnings,
        "decision_reason": (
            decision_res.get("reason")
            or ""
        ),
        "suggested_edits": func.safe_list(
            llm_res.get("suggested_edits")
        ),
        "proposed_final_draft": proposed_draft,
        "final_permitted_draft": (
            final_permitted_draft
        ),
        "outcome_trace": outcome_trace,
        "status": get_status(
            decision,
            awaiting_pv,
        ),
        "preview_outcome": preview_outcome,
        "awaiting_pre_validation": awaiting_pv,
        "execution_time": t.stop(), 
    }


