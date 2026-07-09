"""Unit tests for local, LLM-driven workflow template generation.

Mocks the user's LLM (so no external call) and `db_client`, but exercises
the real TS-bridge validator subprocess end-to-end — parsing the authored
SDK TypeScript is part of the contract the generator relies on, exactly as
`test_mcp_save_workflow.py` does for the MCP tool.
"""

from __future__ import annotations

import shutil

import pytest

import api.services.workflow.template_generation as tg
from api.schemas.user_configuration import UserConfiguration
from api.services.workflow.template_generation import (
    WorkflowGenerationError,
    generate_workflow_from_template,
)

pytestmark = pytest.mark.skipif(
    shutil.which("node") is None, reason="node binary not available"
)


# ─── Fixtures & helpers ──────────────────────────────────────────────────

VALID_TS = """```typescript
import { Workflow } from "@dograh/sdk";
import { startCall, globalNode, agentNode, endCall } from "@dograh/sdk/typed";

const wf = new Workflow({ name: "sales_outbound" });
const g = wf.addTyped(globalNode({ name: "Persona", prompt: "You are Sam, a sales rep." }));
const s = wf.addTyped(startCall({ name: "Open", greeting: "Hi!", prompt: "Open the call.", add_global_prompt: true }));
const a = wf.addTyped(agentNode({ name: "Pitch", prompt: "Pitch the product.", add_global_prompt: true }));
const e = wf.addTyped(endCall({ name: "End", prompt: "Wrap up." }));
wf.edge(s, a, { label: "go", condition: "greeting done" });
wf.edge(a, e, { label: "done", condition: "pitch complete" });
```"""

# Fails validation (a bare `addTyped` result must be assigned to a const),
# so the generator re-prompts with the validator's error message.
INVALID_TS = """
import { Workflow } from "@dograh/sdk";
import { agentNode } from "@dograh/sdk/typed";
const wf = new Workflow({ name: "broken" });
wf.addTyped(agentNode({ name: "Lonely", prompt: "No entry point." }));
"""


class _ScriptedLLM:
    """Fake LLM service returning canned `run_inference` responses in order."""

    def __init__(self, responses: list[str]):
        self._responses = responses
        self.calls = 0

    async def run_inference(self, context, system_instruction=None):
        idx = min(self.calls, len(self._responses) - 1)
        self.calls += 1
        return self._responses[idx]


def _patch(monkeypatch, llm, *, llm_config: dict | None = "default"):
    """Wire a fake LLM + user config into the generator module."""
    if llm_config == "default":
        llm_config = {"provider": "openai", "model": "gpt-4.1", "api_key": "sk-test"}

    async def _get_cfg(_user_id):
        return UserConfiguration(llm=llm_config)

    monkeypatch.setattr(tg.db_client, "get_user_configurations", _get_cfg)
    monkeypatch.setattr(
        tg, "create_llm_service_from_provider", lambda *a, **k: llm
    )


async def _generate():
    return await generate_workflow_from_template(
        call_type="OUTBOUND",
        use_case="Sales outreach",
        activity_description="Call leads and pitch the product.",
        user_id=1,
    )


# ─── Tests ───────────────────────────────────────────────────────────────


async def test_generates_valid_workflow(monkeypatch):
    llm = _ScriptedLLM([VALID_TS])
    _patch(monkeypatch, llm)

    name, payload = await _generate()

    assert llm.calls == 1
    assert name == "sales_outbound"
    assert sorted(n["type"] for n in payload["nodes"]) == [
        "agentNode",
        "endCall",
        "globalNode",
        "startCall",
    ]
    assert len(payload["edges"]) == 2
    # Positions were laid out (not left at the SDK's 0,0 default for reachables).
    assert any(n["position"] != {"x": 0, "y": 0} for n in payload["nodes"])


async def test_retries_on_invalid_then_succeeds(monkeypatch):
    llm = _ScriptedLLM([INVALID_TS, VALID_TS])
    _patch(monkeypatch, llm)

    name, payload = await _generate()

    assert llm.calls == 2  # one retry after validation feedback
    assert name == "sales_outbound"
    assert len(payload["nodes"]) == 4


async def test_raises_after_max_attempts(monkeypatch):
    llm = _ScriptedLLM([INVALID_TS])  # always invalid
    _patch(monkeypatch, llm)

    with pytest.raises(WorkflowGenerationError):
        await _generate()

    assert llm.calls == tg._MAX_ATTEMPTS


async def test_raises_when_no_llm_configured(monkeypatch):
    llm = _ScriptedLLM([VALID_TS])
    _patch(monkeypatch, llm, llm_config=None)

    with pytest.raises(WorkflowGenerationError, match="No LLM is configured"):
        await _generate()

    assert llm.calls == 0  # fails before any inference


async def test_falls_back_to_slug_name_when_missing(monkeypatch):
    # Valid graph, but the Workflow name is blank → generator uses the
    # slug derived from the use case + call type.
    ts = VALID_TS.replace('name: "sales_outbound"', 'name: ""')
    llm = _ScriptedLLM([ts])
    _patch(monkeypatch, llm)

    name, _ = await _generate()

    assert name == "sales_outreach_outbound"
