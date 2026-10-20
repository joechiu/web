# validation_fail_report.py

from promptflow.core import tool

def ensure_list(value) -> list:
    return value if isinstance(value, list) else []

@tool
def main(validation_result=None) -> dict:
    if not isinstance(validation_result, dict):
        return None

    decision = str(validation_result.get("decision", "")).strip().upper()
    if decision not in {"B", "E"}:
        return None

    # Determine status and default fallback message based on decision type
    status = "FAILED" if decision == "B" else "ESCALATED"
    default_reason = "Validation failed." if decision == "B" else "Escalation required."

    trace = validation_result.get("outcome_trace", {})
    outcomes = trace.get("node_outcomes", {})
    findings = {
      "llm_validation_findings": validation_result.get("llm_validation_findings", []),
      "compliance_findings": validation_result.get("compliance_findings", []),
      "evidence_grounding_findings": validation_result.get("evidence_grounding_findings", []),
    }

    return {
        "decision": decision,
        "failure_reason": validation_result.get("decision_reason") or default_reason,
        "validation_findings": findings,
        "fast_outcome": outcomes.get("fast_rule_validator", "NA"),
        "configurable_outcome": outcomes.get("configurable_rules", "NA"),
        "llm_outcome": outcomes.get("unified_llm_validator", "NA"),
        "status": status,
    }

