"""Exotel frame serializer (re-exported from pipecat).

Exotel's Voicebot applet streams raw/slin PCM (16-bit, mono, little-endian,
8 kHz by default) base64-encoded over a WebSocket. ``ExotelFrameSerializer``
handles that wire format plus DTMF and barge-in (``clear``) events.
"""

from pipecat.serializers.exotel import ExotelFrameSerializer

__all__ = ["ExotelFrameSerializer"]
