from types import SimpleNamespace
from unittest.mock import patch

from api.services.configuration.registry import (
    MurfTTSConfiguration,
    ServiceProviders,
)
from api.services.pipecat.audio_config import AudioConfig
from api.services.pipecat.service_factory import create_tts_service


def _audio_config() -> AudioConfig:
    return AudioConfig(transport_in_sample_rate=16000, transport_out_sample_rate=24000)


class TestMurfTTSConfiguration:
    def test_default_values(self):
        config = MurfTTSConfiguration(api_key="test-key")
        assert config.provider == ServiceProviders.MURF
        assert config.model == "FALCON"
        assert config.voice == "Matthew"
        assert config.style == "Conversational"

    def test_custom_values(self):
        config = MurfTTSConfiguration(
            api_key="test-key", model="GEN2", voice="Ruby", style="Promo"
        )
        assert config.model == "GEN2"
        assert config.voice == "Ruby"
        assert config.style == "Promo"


class TestMurfTTSServiceFactory:
    def test_create_murf_tts_service(self):
        user_config = SimpleNamespace(
            tts=SimpleNamespace(
                provider=ServiceProviders.MURF.value,
                api_key="test-key",
                model="FALCON",
                voice="Matthew",
                style="Conversational",
            )
        )

        with patch(
            "api.services.pipecat.service_factory.MurfTTSService"
        ) as mock_service:
            create_tts_service(user_config, _audio_config())

        assert mock_service.call_count == 1
        kwargs = mock_service.call_args.kwargs
        assert kwargs["api_key"] == "test-key"
        assert kwargs["settings"].model == "FALCON"
        assert kwargs["settings"].voice == "Matthew"
        assert kwargs["settings"].style == "Conversational"

    def test_create_murf_tts_service_custom(self):
        user_config = SimpleNamespace(
            tts=SimpleNamespace(
                provider=ServiceProviders.MURF.value,
                api_key="test-key",
                model="GEN2",
                voice="Ruby",
                style="Promo",
            )
        )

        with patch(
            "api.services.pipecat.service_factory.MurfTTSService"
        ) as mock_service:
            create_tts_service(user_config, _audio_config())

        kwargs = mock_service.call_args.kwargs
        assert kwargs["settings"].model == "GEN2"
        assert kwargs["settings"].voice == "Ruby"
        assert kwargs["settings"].style == "Promo"

    def test_style_defaults_when_missing(self):
        # A tts config without a 'style' attribute should fall back to the default.
        user_config = SimpleNamespace(
            tts=SimpleNamespace(
                provider=ServiceProviders.MURF.value,
                api_key="test-key",
                model="FALCON",
                voice="Matthew",
            )
        )

        with patch(
            "api.services.pipecat.service_factory.MurfTTSService"
        ) as mock_service:
            create_tts_service(user_config, _audio_config())

        kwargs = mock_service.call_args.kwargs
        assert kwargs["settings"].style == "Conversational"
