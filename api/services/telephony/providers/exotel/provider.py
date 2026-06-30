"""
Exotel implementation of the TelephonyProvider interface.

Exotel "AgentStream" / Voicebot applet is a WebSocket streaming product: the
media leg runs over a WebSocket configured on a Voicebot applet inside an App
Bazaar flow. There is no SIP/RTP leg on Dograh's side — audio is raw PCM
(slin16) framed by ``ExotelFrameSerializer``.

Call routing model (differs from Twilio/Plivo's markup-response):

* The Voicebot applet's WebSocket URL is configured (statically) in Exotel as
  ``wss://<backend>/api/v1/telephony/exotel/ws``. Dograh resolves *which*
  workflow run a socket belongs to from the ``start`` event, not from the URL
  path:
    - OUTBOUND: ``initiate_call`` places the call into ``flow_app_id`` and
      stores the returned Exotel CallSid on the run. On ``start`` we match
      ``call_sid`` back to that run.
    - INBOUND: the Exophone maps to a flow with the same Voicebot applet. On
      ``start`` we resolve the called number (``to``) to an inbound workflow
      and create the run.

  Both paths live in ``providers/exotel/routes.py`` (the ``/exotel/ws``
  endpoint). ``handle_websocket`` below covers the alternative setup where the
  applet points at the per-run ``/ws/{workflow_id}/{user_id}/{run}`` path.
"""

import json
from typing import TYPE_CHECKING, Any, Dict, List, Optional

import aiohttp
from fastapi import HTTPException
from loguru import logger

from api.db import db_client
from api.enums import WorkflowRunMode
from api.services.telephony.base import (
    CallInitiationResult,
    NormalizedInboundData,
    TelephonyProvider,
)
from api.utils.common import get_backend_endpoints
from api.utils.telephony_address import normalize_telephony_address

if TYPE_CHECKING:
    from fastapi import WebSocket


class ExotelProvider(TelephonyProvider):
    """Exotel (AgentStream / Voicebot applet) implementation of TelephonyProvider."""

    PROVIDER_NAME = WorkflowRunMode.EXOTEL.value
    # Exotel learns the streaming URL from the Voicebot applet, not from a
    # Dograh-rendered markup webhook, so there is no answer-URL endpoint.
    WEBHOOK_ENDPOINT = None

    def __init__(self, config: Dict[str, Any]):
        self.api_key = config.get("api_key")
        self.api_token = config.get("api_token")
        self.account_sid = config.get("account_sid")
        self.subdomain = config.get("subdomain") or "api.exotel.com"
        self.flow_app_id = config.get("flow_app_id")
        self.from_numbers = config.get("from_numbers", [])

        if isinstance(self.from_numbers, str):
            self.from_numbers = [self.from_numbers]

        self.base_url = f"https://{self.subdomain}/v1/Accounts/{self.account_sid}"

    def _auth(self) -> aiohttp.BasicAuth:
        return aiohttp.BasicAuth(self.api_key or "", self.api_token or "")

    # ======== OUTBOUND ========

    async def initiate_call(
        self,
        to_number: str,
        webhook_url: str,
        workflow_run_id: Optional[int] = None,
        from_number: Optional[str] = None,
        **kwargs: Any,
    ) -> CallInitiationResult:
        """Place an outbound call into the Exotel streaming flow.

        Exotel's ``connect`` API calls ``From`` (the customer) and, on answer,
        runs the App/flow at ``Url`` — which contains the Voicebot applet that
        opens the WebSocket back to Dograh. ``CustomField`` carries our
        ``workflow_run_id`` for correlation; we also persist the returned
        Exotel CallSid on the run so the inbound socket can be matched by
        ``call_sid`` as a fallback.

        ``webhook_url`` (the per-run answer URL used by markup providers) is
        ignored here — Exotel does not fetch it.
        """
        if not self.validate_config():
            raise ValueError("Exotel provider not properly configured")

        if not self.flow_app_id:
            raise ValueError(
                "Exotel flow_app_id is not configured. Outbound calls must be "
                "connected into an App Bazaar flow whose Voicebot applet "
                "streams to Dograh. Set flow_app_id in the telephony settings."
            )

        if from_number is None:
            if not self.from_numbers:
                raise ValueError(
                    "No Exophone numbers configured for Exotel provider. At "
                    "least one is required as CallerId for outbound calls."
                )
            import random

            from_number = random.choice(self.from_numbers)

        backend_endpoint, _ = await get_backend_endpoints()
        flow_url = (
            f"http://my.exotel.com/{self.account_sid}/exoml/start_voice/{self.flow_app_id}"
        )

        # Exotel APIs are form-encoded.
        data: Dict[str, Any] = {
            "From": to_number,
            "CallerId": from_number,
            "Url": flow_url,
            "CallType": "trans",
        }
        if workflow_run_id:
            data["CustomField"] = str(workflow_run_id)
            data["StatusCallback"] = (
                f"{backend_endpoint}/api/v1/telephony/exotel/"
                f"status-callback/{workflow_run_id}"
            )

        endpoint = f"{self.base_url}/Calls/connect.json"
        logger.info(
            f"[Exotel] Initiating outbound call to {to_number} from {from_number} "
            f"via flow {self.flow_app_id} (run {workflow_run_id})"
        )

        async with aiohttp.ClientSession() as session:
            async with session.post(endpoint, data=data, auth=self._auth()) as response:
                response_text = await response.text()
                if response.status not in (200, 201, 202):
                    logger.error(
                        f"[Exotel] connect failed: HTTP {response.status} {response_text}"
                    )
                    raise HTTPException(
                        status_code=response.status,
                        detail=f"Failed to initiate Exotel call: {response_text}",
                    )

                response_data = json.loads(response_text)
                call = response_data.get("Call", response_data)
                call_sid = call.get("Sid")
                if not call_sid:
                    raise HTTPException(
                        status_code=500,
                        detail=f"Exotel response missing Call Sid: {response_data}",
                    )

                return CallInitiationResult(
                    call_id=call_sid,
                    status=call.get("Status", "queued"),
                    caller_number=from_number,
                    provider_metadata={"call_id": call_sid},
                    raw_response=response_data,
                )

    async def get_call_status(self, call_id: str) -> Dict[str, Any]:
        if not self.validate_config():
            raise ValueError("Exotel provider not properly configured")

        endpoint = f"{self.base_url}/Calls/{call_id}.json"
        async with aiohttp.ClientSession() as session:
            async with session.get(endpoint, auth=self._auth()) as response:
                if response.status != 200:
                    error_data = await response.text()
                    raise Exception(f"Failed to get Exotel call status: {error_data}")
                return await response.json()

    async def get_call_cost(self, call_id: str) -> Dict[str, Any]:
        endpoint = f"{self.base_url}/Calls/{call_id}.json"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(endpoint, auth=self._auth()) as response:
                    if response.status != 200:
                        error_data = await response.text()
                        logger.error(f"Failed to get Exotel call cost: {error_data}")
                        return {
                            "cost_usd": 0.0,
                            "duration": 0,
                            "status": "error",
                            "error": str(error_data),
                        }
                    payload = await response.json()
                    call = payload.get("Call", payload)
                    # Exotel "Price" is the call charge in the account currency,
                    # returned as a (often negative) string. Normalize to a
                    # positive float; currency is not necessarily USD.
                    raw_price = call.get("Price")
                    try:
                        cost = abs(float(raw_price)) if raw_price not in (None, "") else 0.0
                    except (TypeError, ValueError):
                        cost = 0.0
                    duration = int(call.get("Duration") or 0)
                    return {
                        "cost_usd": cost,
                        "duration": duration,
                        "status": call.get("Status", "unknown"),
                        "price_unit": call.get("Currency", "unknown"),
                        "raw_response": payload,
                    }
        except Exception as e:
            logger.error(f"Exception fetching Exotel call cost: {e}")
            return {"cost_usd": 0.0, "duration": 0, "status": "error", "error": str(e)}

    async def get_available_phone_numbers(self) -> List[str]:
        return self.from_numbers

    def validate_config(self) -> bool:
        return bool(self.api_key and self.api_token and self.account_sid)

    def supports_transfers(self) -> bool:
        return False

    async def transfer_call(
        self,
        destination: str,
        transfer_id: str,
        conference_name: str,
        timeout: int = 30,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        raise NotImplementedError("Exotel provider does not support call transfers")

    # ======== STATUS CALLBACKS ========

    def parse_status_callback(self, data: Dict[str, Any]) -> Dict[str, Any]:
        status_map = {
            "in-progress": "answered",
            "in_progress": "answered",
            "answered": "answered",
            "ringing": "ringing",
            "completed": "completed",
            "busy": "busy",
            "no-answer": "no-answer",
            "failed": "failed",
            "canceled": "canceled",
            "cancelled": "canceled",
        }
        call_status = (data.get("Status") or data.get("CallStatus") or "").lower()
        return {
            "call_id": data.get("CallSid") or data.get("Sid", ""),
            "status": status_map.get(call_status, call_status),
            "from_number": data.get("From") or data.get("CallFrom"),
            "to_number": data.get("To") or data.get("CallTo"),
            "direction": data.get("Direction"),
            "duration": data.get("Duration") or data.get("DialCallDuration"),
            "extra": data,
        }

    # ======== WEBSOCKET ========

    @staticmethod
    async def read_start_event(websocket: "WebSocket") -> Optional[Dict[str, Any]]:
        """Read the Exotel handshake and return the ``start`` payload fields.

        Exotel sends an optional ``connected`` event then a ``start`` event:

            {"event": "start", "stream_sid": "...",
             "start": {"stream_sid", "call_sid", "account_sid", "from", "to",
                       "custom_parameters": {...}, "media_format": {...}}}

        Returns a flat dict (``stream_sid``, ``call_sid``, ``account_sid``,
        ``from_number``, ``to_number``, ``custom_parameters``) or ``None`` if no
        start event arrives.
        """
        for _ in range(3):
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                logger.warning(f"[Exotel] non-JSON ws message during handshake: {raw!r}")
                continue
            event = msg.get("event")
            if event == "connected":
                continue
            if event == "start":
                start = msg.get("start", {}) or {}
                return {
                    "stream_sid": start.get("stream_sid") or msg.get("stream_sid"),
                    "call_sid": start.get("call_sid"),
                    "account_sid": start.get("account_sid"),
                    "from_number": start.get("from"),
                    "to_number": start.get("to"),
                    "custom_parameters": start.get("custom_parameters") or {},
                }
            logger.debug(f"[Exotel] ignoring pre-start ws event: {event}")
        return None

    async def handle_websocket(
        self,
        websocket: "WebSocket",
        workflow_id: int,
        user_id: int,
        workflow_run_id: int,
    ) -> None:
        """Per-run WebSocket path (applet points at /ws/{wf}/{user}/{run}).

        The primary Exotel setup uses the static ``/exotel/ws`` endpoint
        instead; this remains for setups that template the run into the applet
        URL, mirroring the other providers.
        """
        from api.services.pipecat.run_pipeline import run_pipeline_telephony

        start = await self.read_start_event(websocket)
        if not start or not start.get("stream_sid"):
            logger.error(f"[Exotel] missing/invalid start event for run {workflow_run_id}")
            await websocket.close(code=4400, reason="Missing start event")
            return

        workflow_run = await db_client.get_workflow_run_by_id(workflow_run_id)
        call_id = None
        if workflow_run and workflow_run.gathered_context:
            call_id = workflow_run.gathered_context.get("call_id")
        call_id = call_id or start.get("call_sid")

        await run_pipeline_telephony(
            websocket,
            provider_name=self.PROVIDER_NAME,
            workflow_id=workflow_id,
            workflow_run_id=workflow_run_id,
            user_id=user_id,
            call_id=call_id,
            transport_kwargs={
                "stream_sid": start["stream_sid"],
                "call_sid": start.get("call_sid"),
                "call_id": call_id,
            },
        )

    # ======== INBOUND ========

    @classmethod
    def can_handle_webhook(
        cls, webhook_data: Dict[str, Any], headers: Dict[str, str]
    ) -> bool:
        """Detect an Exotel applet HTTP callback.

        Exotel passthru/applet requests carry ``CallSid`` together with the
        Exotel-specific ``CallFrom``/``CallTo`` field names (Twilio uses
        ``From``/``To``/``Caller``/``Called``). This is only used by the
        ``/inbound/run`` and ``/inbound/fallback`` dispatchers; the primary
        Exotel media path is the ``/exotel/ws`` WebSocket.
        """
        has_call_sid = "CallSid" in webhook_data
        has_exotel_fields = "CallFrom" in webhook_data or "CallTo" in webhook_data
        return has_call_sid and has_exotel_fields

    @staticmethod
    def parse_inbound_webhook(webhook_data: Dict[str, Any]) -> NormalizedInboundData:
        from_raw = webhook_data.get("CallFrom") or webhook_data.get("From", "")
        to_raw = webhook_data.get("CallTo") or webhook_data.get("To", "")
        direction = (webhook_data.get("Direction") or "incoming").lower()
        if direction in {"incoming", "inbound"}:
            direction = "inbound"
        return NormalizedInboundData(
            provider=ExotelProvider.PROVIDER_NAME,
            call_id=webhook_data.get("CallSid", ""),
            from_number=normalize_telephony_address(from_raw).canonical
            if from_raw
            else "",
            to_number=normalize_telephony_address(to_raw).canonical if to_raw else "",
            direction=direction,
            call_status=webhook_data.get("CallStatus", "in-progress"),
            account_id=webhook_data.get("AccountSid"),
            raw_data=webhook_data,
        )

    @staticmethod
    def validate_account_id(config_data: dict, webhook_account_id: str) -> bool:
        if webhook_account_id:
            return config_data.get("account_sid") == webhook_account_id
        # Exotel applet callbacks don't always include AccountSid; fall back to
        # confirming the org has an Exotel config at all.
        return bool(config_data.get("account_sid"))

    async def verify_inbound_signature(
        self,
        url: str,
        webhook_data: Dict[str, Any],
        headers: Dict[str, str],
        body: str = "",
    ) -> bool:
        """Exotel applet callbacks are not cryptographically signed.

        Authenticity is enforced on the Exotel side via the applet's optional
        HTTP Basic auth / IP allow-list rather than a per-request signature, so
        there is nothing to verify here. Returning True means "no signature
        verification attempted" (see base class contract).
        """
        return True

    async def start_inbound_stream(
        self,
        *,
        websocket_url: str,
        workflow_run_id: int,
        normalized_data,
        backend_endpoint: str,
    ):
        """Return the dynamic-URL JSON the Voicebot applet expects.

        Used only when the applet is configured with a *dynamic* HTTP URL that
        Exotel fetches per call (pointed at ``/inbound/run``). Exotel reads the
        WebSocket endpoint from ``{"url": "wss://..."}``.
        """
        from fastapi.responses import JSONResponse

        return JSONResponse(content={"url": websocket_url})

    # ======== UNUSED MARKUP HOOKS (Exotel learns the URL from the applet) ====

    async def verify_webhook_signature(
        self, url: str, params: Dict[str, Any], signature: str
    ) -> bool:
        return True

    async def get_webhook_response(
        self, workflow_id: int, user_id: int, workflow_run_id: int
    ) -> str:
        logger.warning(
            "get_webhook_response called for Exotel — Exotel learns the stream "
            "URL from the Voicebot applet, not a Dograh markup response."
        )
        _, wss_backend_endpoint = await get_backend_endpoints()
        return json.dumps(
            {"url": f"{wss_backend_endpoint}/api/v1/telephony/exotel/ws"}
        )

    @staticmethod
    def generate_error_response(error_type: str, message: str) -> tuple:
        from fastapi.responses import JSONResponse

        # No "url" → the Voicebot applet has nothing to stream to and the flow
        # proceeds/ends. This is the Exotel-shaped way to refuse a call.
        return JSONResponse(content={"url": "", "error": message}), "application/json"

    @staticmethod
    def generate_validation_error_response(error_type) -> tuple:
        from fastapi.responses import JSONResponse

        from api.errors.telephony_errors import TELEPHONY_ERROR_MESSAGES, TelephonyError

        message = TELEPHONY_ERROR_MESSAGES.get(
            error_type, TELEPHONY_ERROR_MESSAGES[TelephonyError.GENERAL_AUTH_FAILED]
        )
        return JSONResponse(content={"url": "", "error": message})
