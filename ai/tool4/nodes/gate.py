from promptflow.core import tool
from nodes.tools import *

def normalize_outcome(value, default="N"):
    if value is None:
        return default

    value = str(value).strip().upper()

    value = conf.ALIASES.get(value, value)

    if value in conf.OUTCOMES:
        return value

    return default

def get_outcome(value):
    if isinstance(value, dict):
        return normalize_outcome(
            value.get("outcome")
            or value.get("decision")
            or value.get("status"),
            "N",
        )

    return normalize_outcome(value, "N")

@tool
def main(fast_result=None):

    # P = allow downstream validation
    # S = bypass downstream validation
    outcome = get_outcome(fast_result)

    # PASS
    if outcome == "P":
        return "P"

    # Warning does not stop the validation chain.
    if outcome == "W":
        return "P"

    # Stop downstream validation.
    if outcome == "R":
        return "S"

    # Stop downstream validation.
    if outcome == "B":
        return "S"

    # Stop downstream validation.
    if outcome == "E":
        return "S"

    # A previously skipped stage does not itself prevent
    # downstream stages from executing.
    if outcome == "S":
        return "P"

    # C should normally be converted to S by the validator
    # before reaching this gate.
    if outcome == "C":
        return "S"

    return "S"

