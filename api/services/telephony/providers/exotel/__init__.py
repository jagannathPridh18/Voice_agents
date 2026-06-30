"""Exotel telephony provider package.

Exotel "AgentStream" / Voicebot applet — bidirectional voice streaming over a
WebSocket (raw slin16 PCM). This is the WebSocket product; Exotel's SIP-trunk
products are not wired here (Dograh has no native SIP/RTP transport).
"""

from typing import Any, Dict

from api.services.telephony.registry import (
    ProviderSpec,
    ProviderUIField,
    ProviderUIMetadata,
    register,
)

from .config import ExotelConfigurationRequest, ExotelConfigurationResponse
from .provider import ExotelProvider
from .transport import create_transport


def _config_loader(value: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "provider": "exotel",
        "api_key": value.get("api_key"),
        "api_token": value.get("api_token"),
        "account_sid": value.get("account_sid"),
        "subdomain": value.get("subdomain") or "api.exotel.com",
        "flow_app_id": value.get("flow_app_id"),
        "from_numbers": value.get("from_numbers", []),
    }


_UI_METADATA = ProviderUIMetadata(
    display_name="Exotel",
    docs_url="https://docs.dograh.com/integrations/telephony/exotel",
    fields=[
        ProviderUIField(
            name="api_key", label="API Key", type="text", sensitive=True
        ),
        ProviderUIField(
            name="api_token", label="API Token", type="password", sensitive=True
        ),
        ProviderUIField(
            name="account_sid",
            label="Account SID",
            type="text",
            description="Exotel account identifier (subscribix SID).",
        ),
        ProviderUIField(
            name="subdomain",
            label="API Subdomain",
            type="text",
            required=False,
            description="Regional API host, e.g. api.exotel.com or api.in.exotel.com.",
            placeholder="api.exotel.com",
        ),
        ProviderUIField(
            name="flow_app_id",
            label="Streaming Flow (App) ID",
            type="text",
            required=False,
            description=(
                "App Bazaar flow id whose Voicebot applet streams to Dograh. "
                "Required for outbound calls."
            ),
        ),
        ProviderUIField(
            name="from_numbers",
            label="Exophone Numbers",
            type="string-array",
            description="E.164-formatted Exophone numbers used as caller-id for outbound calls",
        ),
    ],
)


SPEC = ProviderSpec(
    name="exotel",
    provider_cls=ExotelProvider,
    config_loader=_config_loader,
    transport_factory=create_transport,
    transport_sample_rate=8000,
    config_request_cls=ExotelConfigurationRequest,
    config_response_cls=ExotelConfigurationResponse,
    ui_metadata=_UI_METADATA,
    account_id_credential_field="account_sid",
)


register(SPEC)


__all__ = [
    "SPEC",
    "ExotelConfigurationRequest",
    "ExotelConfigurationResponse",
    "ExotelProvider",
    "create_transport",
]
