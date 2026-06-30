"""Exotel telephony routes.

Mounted under ``/api/v1/telephony`` by ``api.routes.telephony`` via the
provider registry.

Two endpoints:

* ``WS /exotel/ws`` — the single, static WebSocket URL configured on every
  Voicebot applet (inbound and outbound flows alike). The owning workflow run
  is resolved from the ``start`` event: outbound calls match the Exotel CallSid
  we stored at ``initiate_call`` time; inbound calls resolve the dialed
  Exophone to its inbound workflow and create the run on the spot.
* ``POST /exotel/status-callback/{workflow_run_id}`` — optional call status
  updates (set as ``StatusCallback`` on outbound calls).
"""

import json
import uuid

from fastapi import APIRouter, Request, WebSocket
from loguru import logger
from pipecat.utils.run_context import set_current_org_id, set_current_run_id
from starlette.websockets import WebSocketDisconnect

from api.db import db_client
from api.enums import CallType, WorkflowRunState
from api.services.quota_service import check_dograh_quota_by_user_id
from api.services.telephony.status_processor import (
    StatusCallbackRequest,
    _process_status_update,
)
from api.utils.telephony_address import normalize_telephony_address

from .provider import ExotelProvider

router = APIRouter()

# Stable provider/account field references so the inbound lookup stays in sync
# with the registry rather than hardcoding strings.
_PROVIDER = ExotelProvider.PROVIDER_NAME
_ACCOUNT_FIELD = "account_sid"


@router.websocket("/exotel/ws")
async def exotel_websocket(websocket: WebSocket):
    """Static Voicebot-applet WebSocket. Resolves the run from the start event."""
    await websocket.accept()
    try:
        await _handle_exotel_ws(websocket)
    except WebSocketDisconnect as e:
        logger.info(f"[Exotel] ws disconnected: code={e.code} reason={e.reason}")
    except Exception as e:
        logger.error(f"[Exotel] ws error: {e}")
        try:
            await websocket.close(code=1011, reason="Internal server error")
        except RuntimeError:
            pass


async def _handle_exotel_ws(websocket: WebSocket) -> None:
    from api.services.pipecat.run_pipeline import run_pipeline_telephony

    start = await ExotelProvider.read_start_event(websocket)
    if not start or not start.get("stream_sid"):
        logger.error("[Exotel] no valid start event on /exotel/ws")
        await websocket.close(code=4400, reason="Missing start event")
        return

    call_sid = start.get("call_sid")
    stream_sid = start["stream_sid"]

    # 1) OUTBOUND: a run already exists carrying this Exotel CallSid.
    workflow_run = (
        await db_client.get_workflow_run_by_call_id(call_sid) if call_sid else None
    )

    if workflow_run is not None:
        await _run_existing(
            websocket,
            run_pipeline_telephony,
            workflow_run=workflow_run,
            stream_sid=stream_sid,
            call_sid=call_sid,
        )
        return

    # 2) INBOUND: resolve the dialed Exophone to an inbound workflow + create run.
    await _run_inbound(
        websocket,
        run_pipeline_telephony,
        start=start,
        stream_sid=stream_sid,
        call_sid=call_sid,
    )


async def _run_existing(
    websocket: WebSocket,
    run_pipeline_telephony,
    *,
    workflow_run,
    stream_sid: str,
    call_sid: str,
) -> None:
    """Start the pipeline for an already-created (outbound) run."""
    workflow_run_id = workflow_run.id
    set_current_run_id(workflow_run_id)

    workflow = await db_client.get_workflow_by_id(workflow_run.workflow_id)
    if not workflow:
        logger.error(f"[Exotel] workflow {workflow_run.workflow_id} not found")
        await websocket.close(code=4404, reason="Workflow not found")
        return

    set_current_org_id(workflow.organization_id)
    call_id = (workflow_run.gathered_context or {}).get("call_id") or call_sid

    await db_client.update_workflow_run(
        run_id=workflow_run_id, state=WorkflowRunState.RUNNING.value
    )
    logger.info(
        f"[Exotel] outbound ws matched run {workflow_run_id} via CallSid {call_sid}"
    )

    await run_pipeline_telephony(
        websocket,
        provider_name=_PROVIDER,
        workflow_id=workflow_run.workflow_id,
        workflow_run_id=workflow_run_id,
        user_id=workflow.user_id,
        call_id=call_id,
        transport_kwargs={
            "stream_sid": stream_sid,
            "call_sid": call_sid,
            "call_id": call_id,
        },
    )


async def _run_inbound(
    websocket: WebSocket,
    run_pipeline_telephony,
    *,
    start: dict,
    stream_sid: str,
    call_sid: str,
) -> None:
    """Resolve the dialed number to an inbound workflow and create the run."""
    to_raw = start.get("to_number") or ""
    from_raw = start.get("from_number") or ""
    account_sid = start.get("account_sid") or ""
    to_number = normalize_telephony_address(to_raw).canonical if to_raw else ""

    if not to_number:
        logger.error(f"[Exotel] inbound ws missing 'to' in start event: {start}")
        await websocket.close(code=4400, reason="Missing called number")
        return

    match = await db_client.find_inbound_route_by_account(
        provider=_PROVIDER,
        account_id_field=_ACCOUNT_FIELD,
        account_id=account_sid,
        to_number=to_number,
        country_hint=None,
    )
    if not match:
        logger.warning(
            f"[Exotel] no inbound route for to={to_number} account_sid={account_sid}"
        )
        await websocket.close(code=4404, reason="No inbound workflow for number")
        return

    config, phone_row = match
    if not phone_row.inbound_workflow_id:
        logger.warning(f"[Exotel] number {to_number} has no inbound_workflow_id")
        await websocket.close(code=4404, reason="Number has no inbound workflow")
        return

    workflow = await db_client.get_workflow(
        phone_row.inbound_workflow_id, organization_id=config.organization_id
    )
    if not workflow:
        logger.warning(
            f"[Exotel] inbound workflow {phone_row.inbound_workflow_id} not found "
            f"for org {config.organization_id}"
        )
        await websocket.close(code=4404, reason="Inbound workflow not found")
        return

    quota_result = await check_dograh_quota_by_user_id(
        workflow.user_id, workflow_id=workflow.id
    )
    if not quota_result.has_quota:
        logger.warning(
            f"[Exotel] quota exceeded for user {workflow.user_id}: "
            f"{quota_result.error_message}"
        )
        await websocket.close(code=1008, reason="Quota exceeded")
        return

    from_number = normalize_telephony_address(from_raw).canonical if from_raw else ""
    numeric_suffix = int(str(uuid.uuid4()).replace("-", "")[:8], 16) % 100000000
    workflow_run = await db_client.create_workflow_run(
        f"WR-TEL-IN-{numeric_suffix:08d}",
        workflow.id,
        _PROVIDER,
        user_id=workflow.user_id,
        call_type=CallType.INBOUND,
        initial_context={
            **(workflow.template_context_variables or {}),
            "caller_number": from_number,
            "called_number": to_number,
            "direction": "inbound",
            "provider": _PROVIDER,
            "telephony_configuration_id": config.id,
        },
        gathered_context={"call_id": call_sid} if call_sid else {},
        logs={
            "inbound_webhook": {
                "account_id": account_sid,
                "from_phone_number_id": phone_row.id,
            },
        },
    )

    workflow_run_id = workflow_run.id
    set_current_run_id(workflow_run_id)
    set_current_org_id(config.organization_id)
    await db_client.update_workflow_run(
        run_id=workflow_run_id, state=WorkflowRunState.RUNNING.value
    )
    logger.info(
        f"[Exotel] inbound ws created run {workflow_run_id} for to={to_number} "
        f"workflow={workflow.id}"
    )

    await run_pipeline_telephony(
        websocket,
        provider_name=_PROVIDER,
        workflow_id=workflow.id,
        workflow_run_id=workflow_run_id,
        user_id=workflow.user_id,
        call_id=call_sid,
        transport_kwargs={
            "stream_sid": stream_sid,
            "call_sid": call_sid,
            "call_id": call_sid,
        },
    )


@router.post("/exotel/status-callback/{workflow_run_id}")
async def handle_exotel_status_callback(workflow_run_id: int, request: Request):
    """Handle Exotel call status callbacks (set as StatusCallback on connect)."""
    set_current_run_id(workflow_run_id)

    content_type = request.headers.get("content-type", "")
    if "application/json" in content_type:
        callback_data = await request.json()
    else:
        form_data = await request.form()
        callback_data = dict(form_data)

    logger.info(
        f"[run {workflow_run_id}] Received Exotel status callback: "
        f"{json.dumps(callback_data, default=str)}"
    )

    workflow_run = await db_client.get_workflow_run_by_id(workflow_run_id)
    if not workflow_run:
        logger.warning(f"Workflow run {workflow_run_id} not found for Exotel callback")
        return {"status": "ignored", "reason": "workflow_run_not_found"}

    workflow = await db_client.get_workflow_by_id(workflow_run.workflow_id)
    if not workflow:
        logger.warning(f"Workflow {workflow_run.workflow_id} not found")
        return {"status": "ignored", "reason": "workflow_not_found"}

    provider = ExotelProvider({})
    parsed_data = provider.parse_status_callback(callback_data)
    status_update = StatusCallbackRequest(
        call_id=parsed_data["call_id"],
        status=parsed_data["status"],
        from_number=parsed_data.get("from_number"),
        to_number=parsed_data.get("to_number"),
        direction=parsed_data.get("direction"),
        duration=parsed_data.get("duration"),
        extra=parsed_data.get("extra", {}),
    )
    await _process_status_update(workflow_run_id, status_update)
    return {"status": "success"}
