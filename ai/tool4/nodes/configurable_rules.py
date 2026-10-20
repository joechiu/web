import re
from promptflow.core import tool
from nodes.tools import *

EMAIL_PATTERN = re.compile(regex.email)

def check_pii(draft):
    return [
        {
            "rule": "PII_EMAIL",
            "severity": "BLOCK",
            "value": email,
        }
        for email in EMAIL_PATTERN.findall(draft)
    ]

def check_regex_patterns(draft, patterns):
    findings = []

    for pattern in map(str, patterns):
        try:
            if re.search(pattern, draft):
                findings.append({
                    "rule": "REGEX_MATCH",
                    "severity": "BLOCK",
                    "pattern": pattern,
                })
        except re.error as exc:
            findings.append({
                "rule": "INVALID_REGEX",
                "severity": "BLOCK",
                "pattern": pattern,
                "error": str(exc),
            })

    return findings

def check_length(draft, min_length, max_length):
    findings = []
    warnings = []
    length = len(draft)

    if length < min_length:
        findings.append({
            "rule": "MIN_LENGTH",
            "severity": "BLOCK",
            "actual_length": length,
            "minimum": min_length,
        })
    elif length > max_length:
        warnings.append({
            "rule": "MAX_LENGTH",
            "severity": "WARNING",
            "actual_length": length,
            "maximum": max_length,
        })

    return findings, warnings

def build_banned_word_pattern(word):
    clean_word = word.strip().lower()
    escaped = re.escape(clean_word)

    variants = {
        "kill": r"kill(?:s|ed|ing|er|ers)?",
    }

    return variants.get(clean_word, escaped)

def check_banned_words(draft, banned_words):
    findings = []

    for item in banned_words:
        word = str(item).strip()

        if not word:
            continue

        pattern = build_banned_word_pattern(word)

        try:
            match = re.search(
                rf"\b{pattern}\b",
                draft,
                flags=re.IGNORECASE,
            )

            if match:
                findings.append({
                    "rule": "BANNED_WORD",
                    "severity": "BLOCK",
                    "word": word,
                    "matched_text": match.group(0),
                })
        except re.error as exc:
            findings.append({
                "rule": "INVALID_BANNED_WORD",
                "severity": "BLOCK",
                "word": word,
                "error": str(exc),
            })

    return findings

def resolve_outcome(findings, warnings):
    if findings:
        return "B"

    if warnings:
        return "W"

    return "P"

@tool
def main(
    draft_output: str,
    enable_pii: bool = True,
    enable_regex: bool = True,
    enable_length: bool = True,
    enable_banned_words: bool = True,
    regex_patterns: list = None,
    banned_words: list = None,
    min_length: int = 1,
    max_length: int = 50000,
    fast_result: dict = None,
) -> dict:

    t = Timer()

    draft = str(draft_output or "")
    regex_patterns = regex_patterns or []
    banned_words = banned_words or []

    findings = []
    warnings = []

    if enable_pii:
        findings.extend(check_pii(draft))

    if enable_regex:
        findings.extend(check_regex_patterns(draft, regex_patterns))

    if enable_length:
        length_findings, length_warnings = check_length(
            draft,
            min_length,
            max_length,
        )
        findings.extend(length_findings)
        warnings.extend(length_warnings)

    if enable_banned_words:
        findings.extend(check_banned_words(draft, banned_words))

    outcome = resolve_outcome(findings, warnings)

    return func.build_response(
        outcome=outcome,
        reason=msg.config.reason,
        findings=findings,
        warnings=warnings,
        hard_stop=False,
        execution_time=t.stop(), 
    )


