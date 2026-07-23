"""Local, LLM-driven workflow generation from a natural-language template.

Replaces the external MPS ``create-workflow`` call. Instead of asking the
Dograh Model Proxy Service to author the graph, we drive the user's *own*
selected LLM — the provider, model, and API key from their model
configuration (``UserConfiguration.llm``) — to emit ``@dograh/sdk``
TypeScript, then reuse the exact TS-bridge validator that the MCP
``create_workflow`` tool uses to turn that source into a validated
workflow definition.

Flow:
    1. Resolve the user's effective LLM config (provider/model/api_key).
    2. Build a one-shot authoring prompt from the live node-spec catalog
       plus the voice-prompting "create" briefing.
    3. Call ``llm.run_inference`` to get SDK TypeScript.
    4. Parse + spec-validate via ``ts_bridge.parse_code``. On failure,
       feed the validator's errors back and retry (bounded).
    5. Reconcile positions and re-validate the DTO / graph before
       returning ``(name, workflow_definition)``.

The Dograh-hosted provider works transparently: ``create_llm_service_from_provider``
builds a ``DograhLLMService`` pointed at the MPS *chat* endpoint
(``{MPS_API_URL}/api/v1/llm``), the same backend used during live calls —
so "use the selected model" holds for every provider without special-casing.
"""

from __future__ import annotations

import json
import random
import re

from loguru import logger
from pipecat.processors.aggregators.llm_context import LLMContext

from api.db import db_client
from api.mcp_server.ts_bridge import TsBridgeError, parse_code
from api.schemas.user_configuration import UserConfiguration
from api.services.pipecat.service_factory import create_llm_service_from_provider
from api.services.voice_prompting_guide import Stage, build_briefing
from api.services.workflow.dto import ReactFlowDTO
from api.services.workflow.layout import reconcile_positions
from api.services.workflow.node_specs import all_specs
from api.services.workflow.trigger_paths import validate_trigger_paths
from api.services.workflow.workflow_graph import WorkflowGraph

# Node types the generator is allowed to compose. Triggers, QA, tuner and
# webhook nodes are out of scope for template generation — keep the spec
# catalog (and the LLM's options) focused on the conversational core.
_CORE_NODE_TYPES = ("startCall", "globalNode", "agentNode", "endCall")

# How many times to re-prompt the LLM with validator feedback before giving up.
_MAX_ATTEMPTS = 3

_CODE_FENCE_RE = re.compile(r"^```[a-zA-Z]*\n?|```$", re.MULTILINE)


class WorkflowGenerationError(Exception):
    """Raised when the selected LLM cannot produce a valid workflow."""


def _extract_code(text: str) -> str:
    """Strip Markdown code fences the model may wrap the source in."""
    text = text.strip()
    if "```" in text:
        # Keep the content of the first fenced block if one is present.
        blocks = re.findall(r"```(?:[a-zA-Z]*)\n(.*?)```", text, re.DOTALL)
        if blocks:
            return blocks[0].strip()
        text = _CODE_FENCE_RE.sub("", text)
    return text.strip()


def _resolve_llm_config(user_config: UserConfiguration) -> tuple[str, str, str, dict]:
    """Extract (provider, model, api_key, service_kwargs) from the user's config.

    Mirrors ``api.services.workflow.qa.llm_config.resolve_user_llm_config`` but
    reads from an already-fetched ``UserConfiguration`` (no workflow run exists
    yet at creation time).
    """
    llm_config = user_config.model_dump(exclude_none=True).get("llm") or {}
    if not llm_config.get("provider"):
        raise WorkflowGenerationError(
            "No LLM is configured. Set a model and API key in Settings → Models "
            "before generating a workflow."
        )

    provider = llm_config["provider"]
    api_key = llm_config.get("api_key", "")
    if isinstance(api_key, list):
        api_key = random.choice(api_key) if api_key else ""
    model = llm_config.get("model", "")

    kwargs: dict = {}
    if provider == "azure":
        kwargs["endpoint"] = llm_config.get("endpoint", "")
    elif llm_config.get("base_url"):
        kwargs["base_url"] = llm_config["base_url"]

    return provider, model, api_key, kwargs


# UI-only spec metadata the authoring model doesn't need — dropped from the
# prompt to cut input tokens (and prefill latency) on every generation attempt.
_SPEC_UI_ONLY_KEYS = frozenset({"icon", "category", "display_name", "version"})


def _core_node_specs_json() -> str:
    specs = [
        {
            k: v
            for k, v in s.model_dump(mode="json").items()
            if k not in _SPEC_UI_ONLY_KEYS
        }
        for s in all_specs()
        if s.name in _CORE_NODE_TYPES
    ]
    # Compact separators (no pretty-print whitespace) — the model parses this
    # fine and it's ~25% smaller than indented JSON.
    return json.dumps(specs, separators=(",", ":"))


def _voice_guide_text() -> str:
    """Render the create-stage voice-prompting briefing as compact guidance."""
    briefing = build_briefing(Stage.create)
    lines = [briefing.get("intro", "").strip(), ""]
    for topic in briefing.get("topics", []):
        title = topic.get("title", "").strip()
        lens = topic.get("lens", "").strip()
        if title and lens:
            lines.append(f"- {title}: {lens}")
    return "\n".join(lines)


_SDK_REFERENCE = """\
Author the workflow as `@dograh/sdk` TypeScript. Follow this exact form:

    import { Workflow } from "@dograh/sdk";
    import { startCall, globalNode, agentNode, endCall } from "@dograh/sdk/typed";

    const wf = new Workflow({ name: "lead_qualification" });

    const global = wf.addTyped(globalNode({
      name: "Persona",
      prompt: "You are Maya, a friendly scheduling assistant for Acme Dental...",
    }));
    const greeting = wf.addTyped(startCall({
      name: "Greeting",
      greeting: "Hi, this is Maya from Acme Dental.",
      prompt: "Greet the caller warmly and ask how you can help.",
      add_global_prompt: true,
    }));
    const qualify = wf.addTyped(agentNode({
      name: "Qualify",
      prompt: "Find out whether the caller wants to book, reschedule, or cancel.",
      add_global_prompt: true,
    }));
    const done = wf.addTyped(endCall({
      name: "Wrap Up",
      prompt: "Thank the caller and confirm next steps before ending.",
    }));

    wf.edge(greeting, qualify, { label: "start", condition: "greeting delivered" });
    wf.edge(qualify, done, { label: "handled", condition: "caller's request is resolved" });

Rules:
- KEEP IT SIMPLE AND MINIMAL. Aim for 3–5 nodes TOTAL: one `startCall`, one or
  two `agentNode`s, and one `endCall` — plus a single `globalNode` only when a
  shared persona is clearly needed. Do NOT build elaborate multi-branch trees or
  add a node per conversational turn. A few well-written prompts beat many nodes,
  and a smaller graph is faster to generate and validate. Only add more nodes if
  the use case genuinely cannot be expressed in 5.
- `new Workflow({ name })` is REQUIRED — set a short snake_case name.
- Exactly ONE `startCall` node (the entry point). At least one `endCall` node.
- Optional: at most ONE `globalNode` for shared persona/tone/rules. Set
  `add_global_prompt: true` on each startCall/agentNode that should inherit it.
- Chain the conversation with `agentNode`s connected by `wf.edge(from, to, { label, condition })`.
  `condition` is natural language describing when to take that transition.
- Every non-start node must be reachable from `startCall` via edges. Every path
  should be able to reach an `endCall`.
- Only use these node types: startCall, globalNode, agentNode, endCall.
- Respect each node's property schema below (field names, types, allowed options)."""


def _build_system_prompt() -> str:
    return (
        "You are an expert designer of voice-AI conversation workflows for the "
        "Dograh platform. Given a use case and a description of what the agent "
        "should do, you author a complete, runnable workflow.\n\n"
        f"{_SDK_REFERENCE}\n\n"
        "=== VOICE PROMPT-WRITING GUIDANCE ===\n"
        f"{_voice_guide_text()}\n\n"
        "=== NODE PROPERTY SCHEMA (authoritative) ===\n"
        f"{_core_node_specs_json()}\n\n"
        "Write natural, concise prompts a voice agent would actually speak and "
        "follow. Output ONLY the TypeScript source — no prose, no explanation, "
        "no Markdown fences."
    )


def _build_user_prompt(
    call_type: str, use_case: str, activity_description: str, workflow_name: str
) -> str:
    return (
        f"Call type: {call_type}\n"
        f"Use case: {use_case}\n"
        f"What the agent should do:\n{activity_description}\n\n"
        f"Use `{workflow_name}` as the Workflow name. Design a SIMPLE, minimal "
        f"{call_type.lower()} call flow (3–5 nodes) for this use case — the "
        "smallest graph that gets the job done — and emit the SDK TypeScript now."
    )


def _slug_name(use_case: str, call_type: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "_", (use_case or "workflow").lower()).strip("_")
    base = base or "workflow"
    return f"{base}_{call_type.lower()}"[:64]


async def generate_workflow_from_template(
    *,
    call_type: str,
    use_case: str,
    activity_description: str,
    user_id: int,
) -> tuple[str, dict]:
    """Generate a workflow definition using the user's selected LLM.

    Returns ``(name, workflow_definition)`` where ``workflow_definition`` is a
    position-reconciled, DTO- and graph-validated ReactFlow payload ready to
    persist. Raises ``WorkflowGenerationError`` if no valid workflow can be
    produced within the retry budget.
    """
    user_config = await db_client.get_user_configurations(user_id)
    provider, model, api_key, service_kwargs = _resolve_llm_config(user_config)

    logger.info(
        f"Generating workflow locally via provider={provider}, model={model}"
    )
    llm = create_llm_service_from_provider(
        provider, model, api_key, **service_kwargs
    )

    fallback_name = _slug_name(use_case, call_type)
    system_prompt = _build_system_prompt()
    messages = [
        {"role": "user", "content": _build_user_prompt(
            call_type, use_case, activity_description, fallback_name
        )},
    ]

    last_error = "unknown error"
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        context = LLMContext()
        context.set_messages(messages)

        try:
            raw = await llm.run_inference(context, system_instruction=system_prompt)
        except Exception as e:  # network / auth / provider errors
            logger.error(f"LLM inference failed on attempt {attempt}: {e}")
            raise WorkflowGenerationError(
                f"The selected model ({provider}/{model}) failed to respond: {e}"
            ) from e

        code = _extract_code(raw or "")
        if not code:
            last_error = "the model returned an empty response"
            logger.warning(f"Attempt {attempt}: empty generation")
            messages.append({"role": "assistant", "content": raw or ""})
            messages.append({
                "role": "user",
                "content": "You returned no code. Output ONLY the SDK TypeScript source.",
            })
            continue

        try:
            parsed = await parse_code(code)
        except TsBridgeError as e:
            last_error = f"validator bridge error: {e}"
            logger.error(f"Attempt {attempt}: {last_error}")
            raise WorkflowGenerationError(last_error) from e

        if not parsed.get("ok"):
            errs = parsed.get("errors") or []
            detail = "; ".join(e.get("message", "") for e in errs) or "validation failed"
            last_error = detail
            logger.warning(f"Attempt {attempt}: parse/validate failed: {detail}")
            messages.append({"role": "assistant", "content": code})
            messages.append({
                "role": "user",
                "content": (
                    "That code failed validation with these errors:\n"
                    f"{detail}\n\n"
                    "Return the FULL corrected TypeScript source (not a patch). "
                    "Output only the code."
                ),
            })
            continue

        payload = parsed["workflow"]
        name = (parsed.get("workflowName") or "").strip() or fallback_name

        # Lay out nodes (SDK positions default to 0,0) and re-validate as a
        # new workflow, mirroring the MCP create_workflow flow.
        payload = reconcile_positions(payload, None)

        trigger_issues = validate_trigger_paths(payload)
        if trigger_issues:
            last_error = "; ".join(i.message for i in trigger_issues)
            logger.warning(f"Attempt {attempt}: trigger validation: {last_error}")
            messages.append({"role": "assistant", "content": code})
            messages.append({
                "role": "user",
                "content": f"Trigger validation failed: {last_error}\nReturn corrected code only.",
            })
            continue

        try:
            dto = ReactFlowDTO.model_validate(payload)
            WorkflowGraph(dto)
        except Exception as e:
            last_error = str(e)
            logger.warning(f"Attempt {attempt}: DTO/graph validation: {last_error}")
            messages.append({"role": "assistant", "content": code})
            messages.append({
                "role": "user",
                "content": f"Graph validation failed: {last_error}\nReturn corrected code only.",
            })
            continue

        logger.info(
            f"Workflow generated in {attempt} attempt(s): "
            f"{len(payload['nodes'])} nodes, {len(payload['edges'])} edges"
        )
        return name, payload

    raise WorkflowGenerationError(
        f"Could not generate a valid workflow after {_MAX_ATTEMPTS} attempts. "
        f"Last error: {last_error}"
    )
