"""Exotel telephony configuration schemas."""

from typing import List, Literal, Optional

from pydantic import BaseModel, Field


class ExotelConfigurationRequest(BaseModel):
    """Request schema for Exotel configuration.

    Exotel's voice streaming (AgentStream / Voicebot applet) authenticates API
    calls with HTTP Basic auth (``api_key`` as username, ``api_token`` as
    password) scoped to an ``account_sid`` on a regional ``subdomain``. The
    actual media leg runs over a WebSocket configured on a Voicebot applet
    inside an App Bazaar flow — ``flow_app_id`` is that flow's id, used to
    place outbound calls into the streaming flow.
    """

    provider: Literal["exotel"] = Field(default="exotel")
    api_key: str = Field(..., description="Exotel API Key (Basic auth username)")
    api_token: str = Field(..., description="Exotel API Token (Basic auth password)")
    account_sid: str = Field(
        ..., description="Exotel Account SID (the account identifier / subscribix sid)"
    )
    subdomain: str = Field(
        default="api.exotel.com",
        description=(
            "Exotel regional API subdomain, e.g. 'api.exotel.com' (Singapore) "
            "or 'api.in.exotel.com' (Mumbai)."
        ),
    )
    flow_app_id: Optional[str] = Field(
        default=None,
        description=(
            "App Bazaar flow (App) id whose Voicebot applet streams audio to "
            "Dograh. Required for OUTBOUND calls — outbound calls are connected "
            "into this flow. Inbound calls reach the flow mapped to the "
            "Exophone, so this is optional if you only use inbound."
        ),
    )
    from_numbers: List[str] = Field(
        default_factory=list,
        description="E.164-formatted Exophone numbers used as caller-id for outbound calls",
    )


class ExotelConfigurationResponse(BaseModel):
    """Response schema for Exotel configuration with masked sensitive fields."""

    provider: Literal["exotel"] = Field(default="exotel")
    api_key: str  # Masked
    api_token: str  # Masked
    account_sid: str
    subdomain: str = "api.exotel.com"
    flow_app_id: Optional[str] = None
    from_numbers: List[str]
