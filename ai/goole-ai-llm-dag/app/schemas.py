from typing import Any, Dict

from pydantic import BaseModel


class DAGRequest(BaseModel):
    prompt: str


class DAGResponse(BaseModel):
    answer: str
    usage: Dict[str, int]
    nodes: Dict[str, Any]
    execution: Dict[str, Any]

