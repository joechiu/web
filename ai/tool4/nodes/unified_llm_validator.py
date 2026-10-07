# unified_llm_validator.py

import re, json 
from promptflow.core import tool
from nodes.tools import *

def parse_json(value):
    if isinstance(value, dict):
        return value, ""

    if not isinstance(value, str) or not value.strip():
        return {}, msg.llm.response_empty

    text = value.strip()
    candidates = [text]

    fenced = re.sub(
        r"^\s*```(?:json)?\s*",
        "",
        text,
        flags=re.IGNORECASE,
    )
    fenced = re.sub(
        r"\s*```\s*$",
        "",
        fenced,
    ).strip()

    if fenced != text:
        candidates.append(fenced)

    first = text.find("{")
    last = text.rfind("}")

    if first >= 0 and last > first:
        candidates.append(text[first:last + 1])

    for candidate in candidates:
        try:
            parsed = json.loads(candidate)

            if isinstance(parsed, dict):
                return parsed, ""

        except (TypeError, ValueError, json.JSONDecodeError):
            pass

    return {}, msg.llm.invalid_json

def normalize_score(value):
    try:
        return max(0, min(4, int(value)))
    except (TypeError, ValueError):
        return 0

def normalize_cefr(value):
    level = str(value or "").strip().upper()
    return level if level in conf.CEFR_LEVELS else None

def normalize_language_match(value):
    return value if isinstance(value, bool) else None

def normalize_quality_scores(value):
    quality = func.safe_dict(value)

    scores = {
        key: normalize_score(quality.get(key))
        for key in conf.QUALITY_KEYS
    }

    total = sum(scores.values())
    maximum = len(conf.QUALITY_KEYS) * 4

    scores["total_score"] = total
    scores["maximum_score"] = maximum
    scores["percentage"] = (
        round(total / maximum * 100, 2)
        if maximum
        else 0.0
    )

    for key in conf.QUALITY_KEYS:
        scores[f"{key}_percentage"] = round(
            scores[key] / 4 * 100,
            2,
        )

    return scores

def normalize_compliance(response):
    compliance = func.safe_dict(
        response.get("compliance")
    )

    return {
        "score": normalize_score(
            compliance.get("score")
        ),
        "mandatory_violation": (
            compliance.get("mandatory_violation") is True
        ),
        "findings": func.safe_list(
            compliance.get("findings")
        ),
    }

def normalize_grounding(response):
    grounding = func.safe_dict(
        response.get("grounding")
    )

    return {
        "unsupported_claims": func.safe_list(
            grounding.get("unsupported_claims")
        ),
        "missing_or_invalid_references": func.safe_list(
            grounding.get("missing_or_invalid_references")
        ),
        "findings": func.safe_list(
            grounding.get("findings")
        ),
    }

def normalize_findings(
    response,
    compliance,
    grounding,
):
    findings = func.safe_list(
        response.get("findings")
    ).copy()

    findings.extend(
        compliance["findings"]
    )

    findings.extend(
        grounding["findings"]
    )

    return func.dedup(findings)

def normalize_outcome(response):
    outcome = str(
        response.get("decision")
        or response.get("outcome")
        or ""
    ).strip().upper()

    return (
        outcome
        if outcome in conf.VALID_OUTCOMES
        else "R"
    )

def normalize_reason(response, outcome):
    reason = response.get("reason")

    if reason:
        return str(reason)

    return conf.REASON_MAPPINGS.get(
        outcome,
        f"Outcome determined as {outcome}.",
    )

def final_response(
    response,
    outcome,
    reason,
    findings,
    compliance,
    grounding,
    quality_scores,
    evidence,
    rules,
    skipped=False,
    token_usage=None,
    execution_time=0.0,
):

    proposed_draft = str(
        response.get("proposed_final_draft")
        or ""
    )
    permitted_draft = (
        proposed_draft
        if outcome == "P"
        else ""
    )
    return func.build_response(
        outcome=outcome,
        decision_hint=outcome,
        reason=reason,
        findings=findings,
        cefr_level=normalize_cefr(
            response.get("cefr_level")
        ),
        language_match=normalize_language_match(
            response.get("language_match")
        ),
        compliance=compliance,
        grounding=grounding,
        quality_scores=quality_scores,
        suggested_edits=func.safe_list(
            response.get("suggested_edits")
        ),
        proposed_final_draft=proposed_draft,
        final_permitted_draft=permitted_draft,
        approved_evidence_references=evidence,
        evidence_count=len(evidence),
        compliance_rule_count=len(rules),
        skipped=skipped,
        token_usage=token_usage,
        execution_time=execution_time,
    )

@tool
def main(
    connection: Connection,
    model: str,
    prompt: str,
    llm_response=None,
    draft_output=None,
    approved_evidence_references=None,
    language_level_requirements=None,
    tone_rules=None,
    compliance_rules=None,
    formatting_rules=None,
    business_policy_rules=None,
    fast_outcome=None,
    configurable_outcome=None,
    **kwargs,
):

    t = Timer()

    if prompt is None:
        return final_response(
            response={},
            outcome="S",
            reason=msg.llm.skip,
            findings=[],
            compliance={
                "score": 0,
                "mandatory_violation": False,
                "findings": [],
            },
            grounding={
                "unsupported_claims": [],
                "missing_or_invalid_references": [],
                "findings": [],
            },
            quality_scores={},
            evidence=[],
            rules=[],
            skipped=True,
            token_usage={},
            execution_time=0.0,
        )

    llm_res = llm.info(
        connection=connection,
        model=model,
        prompt=prompt,
    )
    llm_response = llm_res["response"]
    llm_usage = llm_res["token_usage"]

    evidence = func.safe_list(
        approved_evidence_references
    )

    rules = func.safe_list(
        compliance_rules
    )

    response, parse_error = parse_json(
        llm_response
    )

    if parse_error:
        return final_response(
            response={},
            outcome="R",
            reason=msg.llm.parse_error,
            findings=[
                {
                    "type": "INVALID_LLM_RESPONSE",
                    "details": parse_error,
                    "severity": "REVIEW_REQUIRED",
                }
            ],
            compliance={
                "score": 0,
                "mandatory_violation": False,
                "findings": [],
            },
            grounding={
                "unsupported_claims": [],
                "missing_or_invalid_references": [],
                "findings": [],
            },
            quality_scores={},
            evidence=evidence,
            rules=rules,
            skipped=False,
            token_usage=llm_usage,
            execution_time=t.stop(),
        )

    compliance = normalize_compliance(
        response
    )

    grounding = normalize_grounding(
        response
    )

    findings = normalize_findings(
        response,
        compliance,
        grounding,
    )

    quality_scores = normalize_quality_scores(
        response.get("quality_scores")
    )

    outcome = normalize_outcome(
        response
    )

    if compliance["mandatory_violation"]:
        outcome = "B"

    if normalize_language_match(
        response.get("language_match")
    ) is False:
        outcome = "R"

    if (
        grounding["unsupported_claims"]
        or grounding["missing_or_invalid_references"]
    ):
        outcome = "R"

    reason = normalize_reason(
        response,
        outcome,
    )

    return final_response(
        response=response,
        outcome=outcome,
        reason=reason,
        findings=findings,
        compliance=compliance,
        grounding=grounding,
        quality_scores=quality_scores,
        evidence=evidence,
        rules=rules,
        skipped=False,
        token_usage=llm_usage,
        execution_time=t.stop(),
    )

