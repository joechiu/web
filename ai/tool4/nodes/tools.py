import os, re, sys, json, time
import hashlib, logging
from types import SimpleNamespace
from typing import Dict, Any, Union
from openai import AzureOpenAI, OpenAI
from promptflow.connections import (
    AzureOpenAIConnection,
    OpenAIConnection,
)

# Reusable connection type
Connection = Union[ AzureOpenAIConnection, OpenAIConnection ]

# function class
class func:
  def build_response(**kwargs):
      return {key: value for key, value in kwargs.items()}
  
  def safe_dict(v) -> dict:
      return v if isinstance(v, dict) else {}
  
  def safe_list(v) -> list:
      return v if isinstance(v, list) else []

  def normalize_outcome(v, default="P"):
      if v is None:
          return default
      v = str(v).strip().upper()
      v = conf.ALIASES.get(v, v)
      return v if v in conf.OUTCOMES else default

  def normalize_skipped_result(result):
      if result is None:
          return {
              "hard_stop": True,
              "skipped": True,
              "outcome": "S",
          }
      return result

  def normalize_text(v):
      if v is None:
          return ""
      text = str(v)
      replacements = {
          "\u201c": '"',
          "\u201d": '"',
          "\u2019": "'",
          "\u2013": "-",
          "\u2014": "-",
      }
      for old, new in replacements.items():
          text = text.replace(old, new)
      return re.sub(r"\s+", " ", text).strip().lower()

  def obj(js):
      # dict: convert it directly
      if isinstance(js, dict):
          return json.loads(
              json.dumps(js), object_hook=lambda d: SimpleNamespace(**d)
          )
      # string: parse it directly
      if isinstance(js, str):
          return json.loads(js, object_hook=lambda d: SimpleNamespace(**d))
      return js
    
  def dedup(findings):
      result = []
      seen = set()
      for finding in findings:
          try:
              key = json.dumps(
                  finding,
                  sort_keys=True,
                  default=str,
              )
          except Exception:
              key = str(finding)

          if key in seen:
              continue
          seen.add(key)
          result.append(finding)
      return result

class conf:
  OUTCOMES = { "N", "C", "B", "E", "R", "W", "P", "S" }
  VALID_OUTCOMES = {"B", "R", "W", "P", "E", "S"}
  OUTCOME_LABELS = {
    "B": "BLOCK",
    "R": "REVIEW_REQUIRED",
    "W": "WARNING",
    "P": "PASS",
    "C": "CLEAR",
    "E": "ESCALATE",
    "S": "SKIPPED",
  }
  ALIASES = {
    "NONE": "N",
    "NULL": "N",
    "PASS": "P",
    "PASSED": "P",
    "WARNING": "W",
    "WARN": "W",
    "REVIEW": "R",
    "REVIEW_REQUIRED": "R",
    "REVIEW REQUIRED": "R",
    "REVIEW-REQUIRED": "R",
    "BLOCK": "B",
    "BLOCKED": "B",
    "ESCALATE": "E",
    "ESCALATED": "E",
    "ESCALATION": "E",
    "SKIPPED": "S",
    "CLEAR": "C",
  }
  # decision router ignored outcomes
  IGNORED_OUTCOMES = { "", "NA" }
  # unified llm validator
  QUALITY_KEYS = (
    "grammar_and_tone",
    "language_level_readability",
    "completeness",
    "quality_and_logic",
  )
  REASON_MAPPINGS = {
    "P": "PASS — LLM validation completed successfully.",
    "R": "REVIEW_REQUIRED — LLM validation identified an issue requiring review.",
    "W": "WARNING — LLM validation identified a warning.",
    "B": "BLOCK — LLM validation identified a blocking issue.",
    "E": "ESCALATE — LLM validation requires escalation.",
    "S": "SKIPPED — LLM validation was skipped.",
  }
  CEFR_LEVELS = {"A1", "A2", "B1", "B2", "C1", "C2"}
  # unified llm validator: system-controlled compliance rule trigger terms.
  # if any of these terms appears in a supplied compliance rule,
  # tool4 treats the rule as requiring claims to be supported by approved evidence.
  # these terms are intentionally maintained in code to provide consistent
  # and predictable evidence-grounding behavior across validation runs.
  evidence_terms = (
    "supported by approved evidence",
    "supported by evidence",
    "approved evidence",
    "evidence must support",
    "claims of compliance must be supported",
    "compliance claims must be supported",
  )

class regex:
  # configurable rules
  email = r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"

  # unified llm validator - deterministic compliance checks
  # system-controlled patterns used to detect compliance claims in the draft.
  # these patterns are intentionally not user-configurable.
  # any addition or modification requires a tool4 change request.
  COMPLIANCE_PATTERNS = (
    r"\ball applicable compliance requirements were satisfied\b",
    r"\bapplicable compliance requirements were satisfied\b",
    r"\bcompliance requirements were satisfied\b",
    r"\ball compliance requirements were satisfied\b",
    r"\bthe compliance requirements were satisfied\b",
    r"\bcompliance requirements have been satisfied\b",
    r"\ball applicable requirements were satisfied\b",
    r"\bapplicable requirements were satisfied\b",
    r"\bfully compliant\b",
    r"\bfully complies\b",
    r"\bin compliance with all\b",
    r"\ball applicable .* requirements .* satisfied\b",
  )
  # system-controlled patterns used to detect affirmative compliance
  # statements within approved evidence references.
  # these patterns are intentionally not user-configurable.
  # any addition or modification requires a tool4 change request.
  AFFIRMATIVE_PATTERNS = (
    r"\ball applicable compliance requirements were satisfied\b",
    r"\bapplicable compliance requirements were satisfied\b",
    r"\bcompliance requirements were satisfied\b",
    r"\ball applicable requirements were satisfied\b",
    r"\bapplicable requirements were satisfied\b",
    r"\bcompliance requirements have been satisfied\b",
    r"\bfully compliant\b",
    r"\bfully complies\b",
    r"\bin compliance with all applicable requirements\b",
  )

# tool4 messages class
class msg:
  # inputs validator
  inputs = {
    "init": "Initial submission. Fast Rule Validator must execute.",
    "skip": "Clear from Pre-Validation Human Review cleared the input. Skip Fast Rule Validator.",
    "escalate": "Escalate from Pre-Validation Human Review.",
    "unknown": "Unknown preview status treated as initial submission.",
    "INITIAL_ROUTE": "FAST RULE VALIDATOR",
    "CLEAR_ROUTE": "CONFIGURABLE RULES",
    "ESCALATION_ROUTE": "ESCALATE HARD STOP",
    "OUTCOME_NEUTRAL": "",
    "OUTCOME_CLEAR": "C",
    "OUTCOME_ESCALATED": "E",
  }
  # fast rules validator
  fast = {
    "init": "N - Initial preiview status from Tool3 or Human Review.",
    "skip": "SKIP - Clear from Pre-Validation Human Review cleared the input. Skip Fast Rule Validator.",
    "escalate": "ESCALATE - Escalate from Pre-Validation Human Review.",
    "block": "BLOCK - Upstream validation already returned BLOCK.",
    "review": "Human Pre Validation is required before proceeding to the next validation stage.",
  }
  # configurable rules validator
  config = {
    "reason": "Configurable rule validation completed.",
  }
  # unified llm validator
  llm = {
    "unsupported_grounding": {
      "finding": { "details": "The draft contains a compliance claim that is not supported by the approved evidence." },
      "unsupported_claims": { "reason": "No approved evidence supports the compliance assertion." },
      "suggested_edits": { "message": "Revise or remove the unsupported compliance claim so it matches the approved evidence." },
      "reason": "REVIEW_REQUIRED — The draft contains a compliance claim that is not supported by the approved evidence.",
    },
    "skip": "LLM validation was skipped by the workflow gate.",
    "parse_error": "REVIEW_REQUIRED — LLM validation response could not be parsed reliably.",
    "response_empty": "LLM response is empty or invalid.",
    "invalid_json": "LLM response could not be parsed as valid JSON.",
  }
  # decision router
  decision = {
    "invalid_list": "REVIEW_REQUIRED — Invalid outcome list.",
    "not_active": "NOT_APPLICABLE — No validation node returned an active outcome.",
    "passed": "PASS — All executed validation nodes completed successfully, with no failures or exceptions detected.",
    "pre_review": "REVIEW_REQUIRED — Human Pre Validation is required before proceeding to the next validation stage.",
    "final_review": "REVIEW_REQUIRED — Further review is required before a final decision can be made.",
    "escalate": "ESCALATE — Escalation condition has been identified. Routing to the Decision Router for final determination.",
    "block": "BLOCK — A blocking condition has been identified. Routing to the Decision Router for final determination.",
    "warn_review": "REVIEW_REQUIRED — A WARNING outcome was returned by a validation stage and the chain did not remain a clean PASS sequence.",
  }
  inputs = func.obj(inputs)
  fast = func.obj(fast)
  config = func.obj(config)
  llm = func.obj(llm)
  decision = func.obj(decision)

class llm:

    @staticmethod
    def create_client(connection: Connection):

        conn_dict = dict(connection)

        # Azure OpenAI
        if (
            "api_base" in conn_dict
            or "azure_endpoint" in conn_dict
        ):
            return AzureOpenAI(
                api_key=conn_dict.get("api_key"),
                azure_endpoint=(
                    conn_dict.get("api_base")
                    or conn_dict.get("azure_endpoint")
                ),
                api_version=conn_dict.get(
                    "api_version",
                    "2024-02-01",
                ),
            )

        # Standard OpenAI
        return OpenAI(
            api_key=conn_dict.get("api_key"),
            base_url=conn_dict.get("base_url"),
        )

    @staticmethod
    def info(
        connection: Connection,
        model: str,
        prompt: str,
    ):

        client = llm.create_client(connection)

        response = client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "user",
                    "content": prompt,
                }
            ],
            temperature=0.0,
            seed=993355,
        )

        return {
            "response": response.choices[0].message.content,
            "token_usage": {
                "prompt_tokens": response.usage.prompt_tokens,
                "completion_tokens": response.usage.completion_tokens,
                "total_tokens": response.usage.total_tokens,
                "prompt_length": len(prompt),
                "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                "prompt_words": len(prompt.split()),
                "system_fingerprint": getattr(response, "system_fingerprint", None),
                "model": getattr(response, "model", None),
            },
        }

class Timer:
    def __init__(self):
        self._start = time.perf_counter()

    def stop(self) -> float:
        return round(time.perf_counter() - self._start, 8)



