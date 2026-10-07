# decision_router.py

from promptflow.core import tool
from nodes.tools import *

def get_active_outcomes(outcomes):
    return [
        outcome
        for outcome in outcomes
        if outcome not in conf.IGNORED_OUTCOMES
    ]

def is_clean_pass(active):
    return bool(active) and all(
        outcome == "P"
        for outcome in active[-2:]
    )

def is_clean_block(fast_outcome, active):
    return (
        fast_outcome == "B"
        or all(
            outcome == "B"
            for outcome in active[-2:]
        )
    )

def determine_final_decision(outcomes, node_outcomes):
    if not isinstance(outcomes, list):
        return "R", msg.decision.invalid_list

    active = get_active_outcomes(outcomes)

    if not active:
        return "NA", msg.decision.not_active

    fast_outcome = node_outcomes["fast_rule_validator"]

    if is_clean_pass(active):
        return "P", msg.decision.passed

    if "R" in active:
        if fast_outcome == "R":
            return "R", msg.decision.pre_review

        return "R", msg.decision.final_review

    if "E" in active:
        if fast_outcome == "E":
            return "E", msg.decision.escalate

        return "R", msg.decision.final_review

    if "B" in active:
        if is_clean_block(fast_outcome, active):
            return "B", msg.decision.block

        return "R", msg.decision.final_review

    if "W" in active:
        return "R", msg.decision.warn_review

    return "R", msg.decision.final_review

@tool
def main(
    inputs_result=None,
    fast_result=None,
    configurable_result=None,
    llm_result=None,
    **kwargs,
):

    t = Timer()

    configurable_result = func.normalize_skipped_result(configurable_result)
    llm_result = func.normalize_skipped_result(llm_result)
    inputs = func.safe_dict(inputs_result)
    fast = func.safe_dict(fast_result)
    configurable = func.safe_dict(configurable_result)
    llm = func.safe_dict(llm_result)

    node_outcomes = {
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
    }

    outcomes = list(node_outcomes.values())
    active = get_active_outcomes(outcomes)

    outcome, reason = determine_final_decision(
        outcomes,
        node_outcomes,
    )

    return {
        "outcome": outcome,
        "node_outcomes": node_outcomes,
        "active": active,
        "configurable": configurable,
        # "llm": llm,
        "decision": outcome,
        "reason": reason,
        "execution_time": t.stop(),
    }



