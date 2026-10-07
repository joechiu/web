from promptflow.core import tool
from nodes.tools import *

@tool
def main(preview_status=None) -> dict:

    status = (
        str(preview_status).strip().upper()
        if preview_status is not None
        else ""
    )

    t = Timer()

    # New submission
    if not status:
        return func.build_response(
            outcome=msg.inputs.OUTCOME_NEUTRAL,
            route=msg.inputs.INITIAL_ROUTE,
            human_review_required=False,
            initial_submission=True,
            skip_fast=False,
            reason=msg.inputs.init,
            execution_time=t.stop(),
        )

    # Pre-validation cleared
    if status == msg.inputs.OUTCOME_CLEAR:
        return func.build_response(
            outcome=msg.inputs.OUTCOME_CLEAR,
            route=msg.inputs.CLEAR_ROUTE,
            human_review_required=False,
            initial_submission=False,
            skip_fast=True,
            reason=msg.inputs.skip,
            execution_time=t.stop(),
        )

    # Pre-validation escalated
    if status == msg.inputs.OUTCOME_ESCALATED:
        return func.build_response(
            outcome=msg.inputs.OUTCOME_ESCALATED,
            route=msg.inputs.ESCALATION_ROUTE,
            human_review_required=True,
            initial_submission=False,
            skip_fast=True,
            reason=msg.inputs.escalate,
            execution_time=t.stop(),
        )

    # Unknown preview status
    return func.build_response(
        outcome=msg.inputs.OUTCOME_NEUTRAL,
        route=msg.inputs.INITIAL_ROUTE,
        human_review_required=False,
        initial_submission=False,
        skip_fast=False,
        reason=msg.inputs.unknown,
        execution_time=t.stop(),
    )

