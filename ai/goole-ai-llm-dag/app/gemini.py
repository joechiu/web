"""
Gemini model wrapper.

Provides a single call_gemini() function used by the DAG.

Features:
- Multiple-model fallback
- Retry handling for transient 500/503 errors
- Handles empty-text responses
- Correctly reports candidate/output tokens
- Separates thinking tokens from generated output tokens
- Supports temperature and max_output_tokens
- Disables automatic function calling for normal text generation
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from typing import Any, Optional

from google import genai
from google.genai import types


# ============================================================
# Configuration
# ============================================================

API_KEY = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")

if not API_KEY:
    raise RuntimeError(
        "GEMINI_API_KEY or GOOGLE_API_KEY environment variable is not set."
    )


client = genai.Client(api_key=API_KEY)


# Keep the fallback order conservative.
#
# Gemma is useful when available, but your logs show that it
# frequently returns empty responses.
#
# Gemini Flash is therefore the primary fallback.
#
# The Pro model is intentionally last because your free-tier
# quota has been exhausted for that model.
DEFAULT_MODELS = [
    "gemini-3.1-flash-lite",
    "gemma-4-26b-a4b-it",
    "gemma-4-31b-it",
    "gemini-3.8-flash",
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.5-flash",
]


# ============================================================
# Exceptions
# ============================================================

class GeminiError(Exception):
    """Base Gemini wrapper error."""


class GeminiEmptyResponseError(GeminiError):
    """Gemini returned successfully but produced no text."""


class GeminiTemporaryError(GeminiError):
    """Gemini returned a temporary/server-side error."""


class GeminiQuotaError(GeminiError):
    """Gemini quota was exhausted."""


# ============================================================
# Helpers
# ============================================================

def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _safe_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _extract_usage(response: Any) -> dict[str, int]:
    """
    Extract Gemini token usage.

    Important:
    Some Gemini responses do NOT expose candidates_token_count,
    while thoughts_token_count is present.

    In that case the old implementation reported:

        output_tokens = 0

    even though the model actually generated candidate tokens.

    We use candidates_token_count when available.

    If it is unavailable, we do NOT incorrectly count thought
    tokens as output tokens.

    total_tokens is taken directly from Gemini where possible.
    """

    usage = getattr(response, "usage_metadata", None)

    if usage is None:
        return {
            "input_tokens": 0,
            "output_tokens": 0,
            "thoughts_tokens": 0,
            "total_tokens": 0,
        }

    input_tokens = _safe_int(
        getattr(usage, "prompt_token_count", None)
    )

    output_tokens = _safe_int(
        getattr(usage, "candidates_token_count", None)
    )

    thoughts_tokens = _safe_int(
        getattr(usage, "thoughts_token_count", None)
    )

    total_tokens = _safe_int(
        getattr(usage, "total_token_count", None)
    )

    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "thoughts_tokens": thoughts_tokens,
        "total_tokens": total_tokens,
    }


def _extract_text(response: Any) -> str:
    """
    Extract generated text safely.

    response.text can be None when Gemini returns only thought
    tokens or an otherwise empty candidate.

    We also inspect candidates/parts as a fallback.
    """

    # --------------------------------------------------------
    # First try the SDK convenience property.
    # --------------------------------------------------------

    try:
        text = response.text

        if text:
            text = str(text).strip()

            if text:
                return text

    except Exception:
        pass

    # --------------------------------------------------------
    # Fallback: inspect candidates manually.
    # --------------------------------------------------------

    try:
        candidates = getattr(response, "candidates", None)

        if candidates:
            collected: list[str] = []

            for candidate in candidates:
                content = getattr(candidate, "content", None)

                if content is None:
                    continue

                parts = getattr(content, "parts", None)

                if not parts:
                    continue

                for part in parts:
                    part_text = getattr(part, "text", None)

                    if part_text:
                        collected.append(str(part_text))

            result = "".join(collected).strip()

            if result:
                return result

    except Exception:
        pass

    return ""


def _classify_exception(exc: Exception) -> str:
    """
    Classify Gemini errors for logging/fallback decisions.
    """

    message = str(exc).lower()

    # Quota / rate limit
    if (
        "429" in message
        or "resource_exhausted" in message
        or "quota" in message
        or "rate limit" in message
    ):
        return "QUOTA"

    # Temporary server-side errors
    if (
        "500" in message
        or "internal" in message
        or "503" in message
        or "service unavailable" in message
        or "temporarily unavailable" in message
    ):
        return "TEMPORARY"

    return "OTHER"


def _make_config(
    *,
    max_output_tokens: Optional[int] = None,
    temperature: Optional[float] = None,
) -> types.GenerateContentConfig:
    """
    Build GenerateContentConfig.

    We deliberately do not enable automatic function calling.

    This avoids the AFC warning produced by:

        Models.generate_content()

    for normal text-generation DAG nodes.
    """

    kwargs: dict[str, Any] = {}

    if max_output_tokens is not None:
        kwargs["max_output_tokens"] = int(max_output_tokens)

    if temperature is not None:
        kwargs["temperature"] = float(temperature)

    # Do not pass tools.
    #
    # This is a normal text DAG, not a tool-calling workflow.

    return types.GenerateContentConfig(**kwargs)


# ============================================================
# Single model request
# ============================================================

def _call_model(
    *,
    model: str,
    prompt: str,
    max_output_tokens: Optional[int],
    temperature: Optional[float],
) -> dict[str, Any]:

    started = time.perf_counter()

    print(f"[Gemini] Model={model}")

    config = _make_config(
        max_output_tokens=max_output_tokens,
        temperature=temperature,
    )

    try:
        response = client.models.generate_content(
            model=model,
            contents=prompt,
            config=config,
        )

    except Exception as exc:
        elapsed = time.perf_counter() - started

        error_type = _classify_exception(exc)

        if error_type == "QUOTA":
            print(
                f"[Gemini] {model} quota exhausted."
            )

            raise GeminiQuotaError(str(exc)) from exc

        if error_type == "TEMPORARY":
            print(
                f"[Gemini] {model} temporarily unavailable."
            )

            raise GeminiTemporaryError(str(exc)) from exc

        print(
            f"[Gemini] {model} failed: {exc}"
        )

        raise GeminiError(str(exc)) from exc

    elapsed = time.perf_counter() - started

    usage = _extract_usage(response)

    text = _extract_text(response)

    # --------------------------------------------------------
    # Debug usage information
    # --------------------------------------------------------

    print(
        "[Gemini] Usage "
        f"input={usage['input_tokens']} "
        f"output={usage['output_tokens']} "
        f"thoughts={usage['thoughts_tokens']} "
        f"total={usage['total_tokens']}"
    )

    # --------------------------------------------------------
    # Empty response
    # --------------------------------------------------------

    if not text:
        print(
            f"[Gemini] {model} returned no text "
            f"(thoughts={usage['thoughts_tokens']}, "
            f"total={usage['total_tokens']})"
        )

        raise GeminiEmptyResponseError(
            "Gemini returned no text."
        )

    print(
        f"[Gemini] Completed "
        f"model={model} "
        f"time={elapsed:.2f}s "
        f"input={usage['input_tokens']} "
        f"output={usage['output_tokens']} "
        f"thoughts={usage['thoughts_tokens']} "
        f"total={usage['total_tokens']}"
    )

    return {
        "text": text,
        "model": model,
        "utc_time": _utc_now(),
        "elapsed_seconds": round(elapsed, 2),

        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "thoughts_tokens": usage["thoughts_tokens"],
        "total_tokens": usage["total_tokens"],
    }


# ============================================================
# Public API
# ============================================================

def call_gemini(
    prompt: str,
    *,
    models: Optional[list[str]] = None,
    max_output_tokens: Optional[int] = None,
    temperature: Optional[float] = None,
    retries: int = 2,
    retry_delay: float = 2.0,
    temporary_retry_delay: float = 3.0,
) -> dict[str, Any]:
    """
    Generate text using Gemini with model fallback.

    Parameters
    ----------
    prompt:
        Prompt sent to Gemini.

    models:
        Optional list of models to try.

    max_output_tokens:
        Maximum number of candidate/output tokens.

    temperature:
        Sampling temperature.

    retries:
        Number of retries after the first attempt.

        retries=2 means up to 3 attempts total.

    retry_delay:
        Delay for empty responses/internal errors.

    temporary_retry_delay:
        Delay for 503-style temporary errors.

    Returns
    -------
    dict
        {
            "text": "...",
            "model": "...",
            "utc_time": "...",
            "elapsed_seconds": ...,
            "input_tokens": ...,
            "output_tokens": ...,
            "thoughts_tokens": ...,
            "total_tokens": ...
        }
    """

    if not isinstance(prompt, str):
        raise TypeError("prompt must be a string")

    prompt = prompt.strip()

    if not prompt:
        raise ValueError("prompt cannot be empty")

    model_list = models or DEFAULT_MODELS

    if not model_list:
        raise ValueError("No Gemini models configured")

    failures: list[dict[str, str]] = []

    for model in model_list:

        attempt = 0

        while attempt <= retries:

            attempt += 1

            print(
                f"[Gemini] Model={model} "
                f"Attempt={attempt}"
            )

            try:

                result = _call_model(
                    model=model,
                    prompt=prompt,
                    max_output_tokens=max_output_tokens,
                    temperature=temperature,
                )

                return result

            except GeminiEmptyResponseError as exc:

                failures.append(
                    {
                        "model": model,
                        "type": "EMPTY",
                        "error": str(exc),
                    }
                )

                if attempt <= retries:

                    print(
                        f"[Gemini] {model} returned no text. "
                        f"Retrying in {retry_delay:g} seconds..."
                    )

                    time.sleep(retry_delay)

                    continue

                print(
                    f"[Gemini] {model} failed after "
                    f"{attempt} empty responses. "
                    f"Trying next model."
                )

                break

            except GeminiTemporaryError as exc:

                failures.append(
                    {
                        "model": model,
                        "type": "TEMPORARY",
                        "error": str(exc),
                    }
                )

                if attempt <= retries:

                    print(
                        f"[Gemini] {model} temporarily unavailable. "
                        f"Retrying in "
                        f"{temporary_retry_delay:g} seconds..."
                    )

                    time.sleep(temporary_retry_delay)

                    continue

                print(
                    f"[Gemini] {model} unavailable after "
                    f"{attempt} attempts. "
                    f"Trying next model."
                )

                break

            except GeminiQuotaError as exc:

                failures.append(
                    {
                        "model": model,
                        "type": "QUOTA",
                        "error": str(exc),
                    }
                )

                print(
                    f"[Gemini] {model} quota exhausted. "
                    f"Trying next model."
                )

                break

            except GeminiError as exc:

                failures.append(
                    {
                        "model": model,
                        "type": "ERROR",
                        "error": str(exc),
                    }
                )

                print(
                    f"[Gemini] {model} failed: {exc}. "
                    f"Trying next model."
                )

                break

            except Exception as exc:

                failures.append(
                    {
                        "model": model,
                        "type": "UNKNOWN",
                        "error": str(exc),
                    }
                )

                print(
                    f"[Gemini] {model} unexpected error: "
                    f"{exc}. Trying next model."
                )

                break

    # ========================================================
    # Everything failed
    # ========================================================

    print("[Gemini] ALL MODELS FAILED")

    for failure in failures:
        print(
            f"[Gemini] "
            f"{failure['model']} "
            f"type={failure['type']}"
        )

    if failures:

        last_error = failures[-1]["error"]

        raise GeminiError(
            "All Gemini models failed. "
            f"Last error: {last_error}"
        )

    raise GeminiError(
        "All Gemini models failed."
    )


# ============================================================
# Simple standalone test
# ============================================================

if __name__ == "__main__":

    print("=" * 60)
    print("Testing Gemini")
    print("=" * 60)

    result = call_gemini(
        "Say hello in exactly one short sentence.",
        max_output_tokens=3032,
        temperature=0.2,
    )

    print()
    print("RESULT")
    print("=" * 60)
    print(result)


