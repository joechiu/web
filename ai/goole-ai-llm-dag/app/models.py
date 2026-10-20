from typing import Dict, Optional

from pydantic import BaseModel, Field


class DAGRequest(BaseModel):
    prompt: str = Field(..., min_length=1)


class NodeResult(BaseModel):
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    elapsed_seconds: float = 0.0
    text: str = ""


class UsageSummary(BaseModel):
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0

    # Your DAG's reported token sum.
    # This is useful for monitoring, but Google may report
    # total_token_count differently from input + output.
    reported_total_tokens: int = 0

    nodes: Dict[str, NodeResult] = {}


class DAGResponse(BaseModel):
    answer: str
    usage: UsageSummary
    nodes: Dict[str, NodeResult]
