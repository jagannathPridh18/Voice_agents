"""Per-agent language support.

A single, canonical *agent language* selected at workflow-creation time and
stored at ``workflow_configurations["language"]``. It drives three things at
runtime:

1. **STT (listen)** — the transcription service is told to expect that
   language, where the configured provider supports it.
2. **TTS (speak)** — the synthesis service is told to speak that language,
   but only for providers whose voices are language-agnostic (setting a
   language on a voice-locked provider would mispronounce or error, so we
   leave those alone and rely on the LLM directive + the provider's model).
3. **LLM (respond)** — a hard system-prompt directive instructing the model
   to converse *only* in that language. This is the real enforcement: TTS
   merely narrates whatever text the LLM produces, so the language the agent
   "speaks" is ultimately decided by the LLM output.

Because every provider expects a different code format for the same language
(Deepgram ``hi``, Sarvam/Google ``hi-IN``, …), translation is table-driven per
provider. Unsupported (provider, language) pairs fall through to the
provider's own default so a call never breaks — the LLM directive still keeps
the conversation in-language.
"""

from __future__ import annotations

from loguru import logger

from api.services.configuration.registry import ServiceProviders

# ---------------------------------------------------------------------------
# Canonical agent languages
# ---------------------------------------------------------------------------
# ``code`` is the value stored on the workflow and accepted by the API/SDK.
# ``label`` (with native script) is injected into the LLM directive so the
# model is unambiguous about which language is meant.

AGENT_LANGUAGES: tuple[dict[str, str], ...] = (
    {"code": "en", "label": "English"},
    {"code": "hi", "label": "Hindi (हिन्दी)"},
    {"code": "bn", "label": "Bengali (বাংলা)"},
    {"code": "ta", "label": "Tamil (தமிழ்)"},
    {"code": "te", "label": "Telugu (తెలుగు)"},
    {"code": "kn", "label": "Kannada (ಕನ್ನಡ)"},
    {"code": "gu", "label": "Gujarati (ગુજરાતી)"},
    {"code": "mr", "label": "Marathi (मराठी)"},
    {"code": "ml", "label": "Malayalam (മലയാളം)"},
    {"code": "pa", "label": "Punjabi (ਪੰਜਾਬੀ)"},
)

LANGUAGE_LABELS: dict[str, str] = {lang["code"]: lang["label"] for lang in AGENT_LANGUAGES}

SUPPORTED_LANGUAGE_CODES: frozenset[str] = frozenset(LANGUAGE_LABELS)


def is_supported_language(code: str | None) -> bool:
    """True when *code* is a recognized agent-language code."""
    return bool(code) and code in SUPPORTED_LANGUAGE_CODES


# ---------------------------------------------------------------------------
# Per-provider language-code tables
# ---------------------------------------------------------------------------
# A canonical code maps to the exact string each provider expects. A code that
# is absent from a provider's table means "this provider can't do that
# language" — we then leave the provider's own default in place rather than
# passing a code it would reject.

# STT: providers whose language codes we know and can set safely.
# Deepgram and the Dograh managed STT share the same code set (Dograh proxies
# the same engine — DOGRAH_STT_LANGUAGES == DEEPGRAM_LANGUAGES), so both cover
# en/hi/bn/ta/te/kn/mr and lack gu/ml/pa (which fall back to "multi").
_DEEPGRAM_FAMILY_STT = {
    "en": "en",
    "hi": "hi",
    "bn": "bn",
    "ta": "ta",
    "te": "te",
    "kn": "kn",
    "mr": "mr",
}

_STT_CODES: dict[str, dict[str, str]] = {
    # Deepgram (default STT for self-hosted API keys). nova-3 has no gu/ml/pa.
    ServiceProviders.DEEPGRAM.value: _DEEPGRAM_FAMILY_STT,
    # Dograh managed STT (the default provider for hosted/OSS users).
    ServiceProviders.DOGRAH.value: _DEEPGRAM_FAMILY_STT,
    # Sarvam — purpose-built for Indian languages; covers all ten.
    ServiceProviders.SARVAM.value: {
        "en": "en-IN",
        "hi": "hi-IN",
        "bn": "bn-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "kn": "kn-IN",
        "gu": "gu-IN",
        "mr": "mr-IN",
        "ml": "ml-IN",
        "pa": "pa-IN",
    },
    # Google Cloud STT — covers all ten via BCP-47 -IN codes.
    ServiceProviders.GOOGLE.value: {
        "en": "en-IN",
        "hi": "hi-IN",
        "bn": "bn-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "kn": "kn-IN",
        "gu": "gu-IN",
        "mr": "mr-IN",
        "ml": "ml-IN",
        "pa": "pa-IN",
    },
    # Azure Speech — only en-IN / hi-IN are broadly available.
    ServiceProviders.AZURE_SPEECH.value: {
        "en": "en-IN",
        "hi": "hi-IN",
    },
}

# TTS: only providers whose voices are language-agnostic can have a language
# set without also swapping the voice. Sarvam decouples voice from language,
# so it's safe. Voice-locked providers (Google/Azure/ElevenLabs) are left
# untouched — their pronunciation follows the configured voice/model and the
# LLM directive keeps the text in-language.
_TTS_CODES: dict[str, dict[str, str]] = {
    ServiceProviders.SARVAM.value: {
        "en": "en-IN",
        "hi": "hi-IN",
        "bn": "bn-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "kn": "kn-IN",
        "gu": "gu-IN",
        "mr": "mr-IN",
        "ml": "ml-IN",
        "pa": "pa-IN",
    },
}

# Realtime (speech-to-speech) — Gemini Live accepts BCP-47 -IN codes.
_REALTIME_CODES: dict[str, dict[str, str]] = {
    ServiceProviders.GOOGLE_REALTIME.value: {
        "en": "en-IN",
        "hi": "hi-IN",
        "bn": "bn-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "kn": "kn-IN",
        "gu": "gu-IN",
        "mr": "mr-IN",
        "ml": "ml-IN",
        "pa": "pa-IN",
    },
    ServiceProviders.GOOGLE_VERTEX_REALTIME.value: {
        "en": "en-IN",
        "hi": "hi-IN",
        "bn": "bn-IN",
        "ta": "ta-IN",
        "te": "te-IN",
        "kn": "kn-IN",
        "gu": "gu-IN",
        "mr": "mr-IN",
        "ml": "ml-IN",
        "pa": "pa-IN",
    },
}


def stt_language_code(provider: str | None, language: str | None) -> str | None:
    """Provider-specific STT code for *language*, or None if unsupported."""
    if not provider or not language:
        return None
    return _STT_CODES.get(provider, {}).get(language)


def tts_language_code(provider: str | None, language: str | None) -> str | None:
    """Provider-specific TTS code for *language*, or None if unsupported."""
    if not provider or not language:
        return None
    return _TTS_CODES.get(provider, {}).get(language)


def realtime_language_code(provider: str | None, language: str | None) -> str | None:
    """Provider-specific realtime code for *language*, or None if unsupported."""
    if not provider or not language:
        return None
    return _REALTIME_CODES.get(provider, {}).get(language)


# ---------------------------------------------------------------------------
# LLM directive
# ---------------------------------------------------------------------------


def language_directive(language: str | None) -> str | None:
    """System-prompt directive forcing the model to converse only in *language*.

    Returns None for an unset/unknown language so callers can skip injection.
    """
    label = LANGUAGE_LABELS.get(language or "")
    if not label:
        return None
    return (
        f"CRITICAL LANGUAGE REQUIREMENT: You MUST conduct this entire "
        f"conversation ONLY in {label}. Every single response — greetings, "
        f"questions, confirmations, and closings — must be written in {label}. "
        f"Do NOT switch to English or any other language, and do NOT mix "
        f"languages, even if the user speaks or writes in a different language. "
        f"If the user uses another language, understand them but always reply "
        f"in {label}."
    )


def apply_agent_language(user_config, language: str | None) -> None:
    """Set STT/TTS/realtime language on *user_config* for the agent language.

    Mutates the passed config in place (callers pass a resolved, owned copy).
    Only touches sections whose provider supports the language and whose config
    actually exposes a ``language`` field; everything else is left untouched so
    no call ever breaks on an unsupported combination.
    """
    if not is_supported_language(language):
        return

    stt = getattr(user_config, "stt", None)
    if stt is not None and hasattr(stt, "language"):
        provider = getattr(stt, "provider", None)
        code = stt_language_code(provider, language)
        if code is not None:
            stt.language = code
            logger.info(f"Agent language '{language}': set STT ({provider}) language={code}")
        else:
            logger.warning(
                f"Agent language '{language}': STT provider '{provider}' has no mapping "
                f"for this language — STT will not be pinned. Use Sarvam/Google for full "
                f"Indian-language STT coverage."
            )
    elif stt is not None:
        logger.warning(
            f"Agent language '{language}': STT provider "
            f"'{getattr(stt, 'provider', None)}' exposes no language field — cannot pin STT."
        )

    tts = getattr(user_config, "tts", None)
    if tts is not None and hasattr(tts, "language"):
        provider = getattr(tts, "provider", None)
        code = tts_language_code(provider, language)
        if code is not None:
            tts.language = code
            logger.info(f"Agent language '{language}': set TTS ({provider}) language={code}")
        else:
            logger.warning(
                f"Agent language '{language}': TTS provider '{provider}' has no language "
                f"mapping — TTS pronunciation follows the selected voice. Use Sarvam for "
                f"reliable Indian-language speech."
            )
    elif tts is not None:
        logger.warning(
            f"Agent language '{language}': TTS provider "
            f"'{getattr(tts, 'provider', None)}' exposes no language field (e.g. Dograh, "
            f"ElevenLabs, Murf) — the agent cannot be pinned to speak this language via TTS. "
            f"Switch TTS to Sarvam for reliable Indian-language speech."
        )

    realtime = getattr(user_config, "realtime", None)
    if realtime is not None and hasattr(realtime, "language"):
        code = realtime_language_code(getattr(realtime, "provider", None), language)
        if code is not None:
            realtime.language = code
