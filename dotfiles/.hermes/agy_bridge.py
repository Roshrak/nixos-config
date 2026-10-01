#!/usr/bin/env python3
"""
OpenAI-compatible local HTTP adapter bridging Hermes to Google Antigravity (agy)
running Gemini 3.8 Flash High under official Google AI Pro subscription quota.
Fresh process per turn ensures zero state pollution, zero buffer leaks, and zero repetition loops.
"""

import asyncio
import contextlib
import json
import logging
import os
import re
import shutil
import signal
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from aiohttp import ClientConnectionError, web

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("AgyBridge")

def resolve_agy_bin() -> str:
    candidate_env = os.environ.get("AGY_BIN")
    if candidate_env and Path(candidate_env).is_file() and os.access(candidate_env, os.X_OK):
        return candidate_env

    which_bin = shutil.which("agy")
    if which_bin and Path(which_bin).is_file() and os.access(which_bin, os.X_OK):
        return which_bin

    for candidate in (
        "/run/current-system/sw/bin/agy",
        "/home/aesc/.nix-profile/bin/agy",
        "/home/aesc/.local/bin/agy",
    ):
        if Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate

    for match in sorted(Path("/nix/store").glob("*-antigravity-cli-*/bin/agy"), reverse=True):
        if match.is_file() and os.access(match, os.X_OK):
            return str(match)

    return "agy"


AGY_BIN = resolve_agy_bin()
PORT = 8765
HOST = "127.0.0.1"
MODEL_IDS = (
    "gemini-3.8-flash-medium",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-low",
)
DEFAULT_MODEL = "gemini-3.8-flash-medium"
DEFAULT_EFFORT = "medium"
SUPPORTED_EFFORTS = ("low", "medium", "high")
SUPPORTED_MODEL_ALIASES = {
    "gemini-3.8-flash": "gemini-3.8-flash-medium",
    "openai/gemini-3.8-flash": "gemini-3.8-flash-medium",
    "openai/gemini-3.8-flash-medium": "gemini-3.8-flash-medium",
    "openai/gemini-3.8-flash-high": "gemini-3.8-flash-high",
    "openai/gemini-3.8-flash-low": "gemini-3.8-flash-low",
}
ALL_SUPPORTED_MODELS = tuple(MODEL_IDS) + tuple(SUPPORTED_MODEL_ALIASES.keys())


def normalize_model(model: str | None, *, raise_on_error: bool = False) -> str | None:
    """Normalize a canonical AGY model ID or OpenAI alias.

    Returns the canonical AGY model ID (e.g. 'gemini-3.8-flash-medium') if supported,
    or None if the model is unknown or unsupported (raises ValueError if raise_on_error=True).
    """
    if not model or not isinstance(model, str):
        if raise_on_error:
            raise ValueError("model must be a non-empty string")
        return None
    raw = model.strip()
    if not raw:
        if raise_on_error:
            raise ValueError("model must be a non-empty string")
        return None
    raw_lower = raw.lower()

    if raw_lower in MODEL_IDS:
        return raw_lower
    if raw_lower in SUPPORTED_MODEL_ALIASES:
        return SUPPORTED_MODEL_ALIASES[raw_lower]

    if raise_on_error:
        raise ValueError(f"Unsupported model: {model!r}. Supported models: {', '.join(ALL_SUPPORTED_MODELS)}")
    return None


def normalize_reasoning_effort(effort: Any = None, model: str | None = None) -> str:
    """Normalize reasoning_effort case-insensitively and map to intended AGY model tier.

    If effort is omitted (None or empty string), uses the model's explicit tier if present,
    or the documented bridge default ('gemini-3.8-flash-medium').
    Raises ValueError on invalid reasoning_effort or unsupported model.
    """
    if effort is not None and effort != "":
        if not isinstance(effort, str):
            raise ValueError(f"Invalid reasoning_effort: {effort!r}. Expected one of {SUPPORTED_EFFORTS}.")
        effort_clean = effort.strip().lower()
        if effort_clean not in SUPPORTED_EFFORTS:
            raise ValueError(f"Invalid reasoning_effort: {effort!r}. Supported values are: {', '.join(SUPPORTED_EFFORTS)}.")
    else:
        effort_clean = None

    if model is not None and model != "":
        norm_model = normalize_model(model, raise_on_error=True)
    else:
        norm_model = DEFAULT_MODEL

    if effort_clean is not None:
        return f"gemini-3.8-flash-{effort_clean}"

    return norm_model


def resolve_model_and_effort(model: str | None = None, reasoning_effort: Any = None) -> tuple[str, str]:
    """Resolve normalized canonical AGY model name and effort level."""
    selected_model = normalize_reasoning_effort(reasoning_effort, model=model)
    effort = selected_model.rsplit("-", 1)[-1]
    return selected_model, effort


def read_bridge_timeout() -> int | None:
    """Return the bridge deadline, or ``None`` when the deadline is disabled.

    A normal agent turn can legitimately outlive a short request timeout while
    it delegates, reads a repository, or waits for a tool.  ``0`` (and the
    named unlimited values) therefore disable only this outer bridge deadline;
    client cancellation still tears down the child process in ``finally``.
    """
    raw_value = os.environ.get("AGY_BRIDGE_TIMEOUT_SECONDS", "0").strip().lower()
    if raw_value in {"", "0", "none", "off", "unlimited", "infinite"}:
        return None
    try:
        return max(1, int(raw_value))
    except ValueError:
        logger.warning(
            "Invalid AGY_BRIDGE_TIMEOUT_SECONDS=%r; disabling the outer bridge deadline",
            raw_value,
        )
        return None


AGY_TIMEOUT_SECONDS = read_bridge_timeout()
# The agy CLI itself defaults to five minutes.  Keep a deliberately long
# process deadline when the outer deadline is disabled, because agy requires
# a concrete Go-duration value rather than an infinite-duration sentinel.
AGY_PRINT_TIMEOUT = os.environ.get("AGY_PRINT_TIMEOUT") or (
    f"{AGY_TIMEOUT_SECONDS}s" if AGY_TIMEOUT_SECONDS is not None else "24h"
)


def read_post_result_timeout() -> float:
    """Return the timeout in seconds to wait for agy process termination after result event."""
    raw_value = os.environ.get("AGY_POST_RESULT_TIMEOUT_SECONDS", "3.0").strip().lower()
    try:
        return max(0.01, float(raw_value))
    except ValueError:
        return 3.0


POST_RESULT_TIMEOUT_SECONDS = read_post_result_timeout()


def build_prompt_with_tools(messages, tools):
    system_instructions = []
    turns = []
    for m in messages:
        role = m.get("role")
        content = m.get("content") or ""
        if isinstance(content, list):
            text_parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    text_parts.append(part.get("text", ""))
                elif isinstance(part, str):
                    text_parts.append(part)
            content = "".join(text_parts)
        if role == "system":
            if "[System note:" not in content and "Cutoff:" not in content:
                system_instructions.append(content)
        else:
            turns.append({**m, "content": content})

    recent_turns = turns[-10:] if len(turns) > 10 else turns

    lines = []
    if tools:
        lines.append("You are the AI Operating Brain of an advanced NixOS desktop assistant connected to Telegram.")
        lines.append("### CRITICAL INFERENCE BOUNDARY:")
        lines.append("You are acting purely as an inference model backend for Hermes Agent on Telegram.")
        lines.append("You MUST NOT execute tools or run commands natively. NEVER invoke native tools, MCP tools, or subagents.")
        lines.append("To execute any tool, output ONLY a <tool_call> block in plain text.")

    if system_instructions:
        lines.append("\n### CORE SYSTEM DIRECTIVES:")
        for s in system_instructions:
            lines.append(s)

    if tools:
        lines.append("\n### AVAILABLE LIVE TOOLS:")
        for t in tools:
            fn = t.get("function", {})
            name = fn.get("name")
            desc = fn.get("description", "")
            params = fn.get("parameters", {}).get("properties", {})
            param_list = [f"{p}" for p in params.keys()]
            lines.append(f"- `{name}({', '.join(param_list)})`: {desc}")

        lines.append(
            "\n### STRICT EXECUTION & ANTI-HALLUCINATION PROTOCOL:\n"
            "1. NEVER GUESS OR HALLUCINATE: You do not possess real-time information in your internal memory for second-hand prices, flight fares, hardware deals, file contents, or laptop state. You MUST CALL A TOOL.\n"
            "2. TOOL CALLING SYNTAX: To invoke ANY tool, output ONLY a tool call block in this format:\n"
            "<tool_call>\n"
            "{\"name\": \"TOOL_NAME\", \"arguments\": {\"ARG_NAME\": \"ARG_VALUE\"}}\n"
            "</tool_call>\n\n"
            "3. ACTION MAPPING RULES:\n"
            "   - **Terminal Commands / System Status / Fastfetch**:\n"
            "     * Command execution: <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"fastfetch\"}}</tool_call>\n"
            "     * On Screen / Monitor: <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"nohup kitty --hold -e <command> >/dev/null 2>&1 &\"}}</tool_call>\n"
            "     * Media / Music (Always reuse the existing tab): <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"~/.local/bin/ytmusic_control.py play '<query>'\"}}</tool_call>\n"
            "     * Switch Song / Next Track (NEVER open a new tab): <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"~/.local/bin/ytmusic_control.py next '<optional query>'\"}}</tool_call>\n"
            "   - **Software Factory & Coding Tasks (softfac, codebase analysis, debugging)**:\n"
            "     * Output tool call: <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"softfac run '<task>'\"}}</tool_call>\n"
            "   - **Hardware & GPU Prices / Sellers (7800xt, 6800xt, GPUs)**:\n"
            "     * NEVER invent price ranges or output generic shopping tips.\n"
            "     * Run the dedicated marketplace engine immediately: <tool_call>{\"name\": \"terminal\", \"arguments\": {\"command\": \"~/.local/bin/gpu_market_search.py '<query>'\"}}</tool_call>\n"
            "   - **Flight Prices & Live Web Data**:\n"
            "     * Search the live web using `web_search`: <tool_call>{\"name\": \"web_search\", \"arguments\": {\"query\": \"<search query>\"}}</tool_call>\n"
            "     * Or write and run a Python scraper via `execute_code` or `terminal`.\n"
            "   - **Computing & Plotting Visual Charts**:\n"
            "     * Call `execute_code` with Python (using matplotlib or PIL to save image and send via Telegram API).\n"
            "4. NEVER ask for permission. NEVER return an empty response. To perform any action, output the required <tool_call> block immediately in plain text. Do not execute anything natively."
        )

    last_role = recent_turns[-1].get("role") if recent_turns else ""
    if last_role == "tool":
        lines.append(
            "\n### TOOL RESULT EVALUATION:\n"
            "The tool has executed with the output provided in the conversation above.\n"
            "Analyze the output carefully and present a concise, grounded, concrete summary to the user.\n"
            "Include exact prices, seller names, links, and confirm if a chart was sent. DO NOT output textbook shopping advice."
        )

    lines.append("\n### CONVERSATION HISTORY:")
    for m in recent_turns:
        role = m.get("role")
        content = m.get("content") or ""
        if role == "user":
            lines.append(f"User: {content}")
        elif role == "assistant":
            tc = m.get("tool_calls")
            if tc and content:
                lines.append(f"Assistant: {content}\nAssistant (Tool Invocation): {json.dumps(tc)}")
            elif tc:
                lines.append(f"Assistant (Tool Invocation): {json.dumps(tc)}")
            elif content:
                lines.append(f"Assistant: {content}")
        elif role == "tool":
            tool_content = str(content) if not isinstance(content, str) else content
            if len(tool_content) > 10000:
                tool_content = tool_content[:5000] + "\n... [truncated] ...\n" + tool_content[-5000:]
            lines.append(f"Tool Output:\n{tool_content}")

    lines.append("\nAssistant:")
    return "\n".join(lines)

def parse_tool_calls(text):
    matches = re.findall(r"<tool[-_]calls?\s*>(.*?)</tool[-_]calls?>", text, re.DOTALL | re.IGNORECASE)
    tool_calls = []

    for raw in matches:
        candidate_str = raw.strip()
        candidate_str = re.sub(r"^```(?:json)?\s*", "", candidate_str, flags=re.IGNORECASE)
        candidate_str = re.sub(r"\s*```$", "", candidate_str)
        try:
            data = json.loads(candidate_str)
        except Exception:
            try:
                candidate_str = re.sub(r"//.*$", "", candidate_str, flags=re.MULTILINE)
                candidate_str = re.sub(r",\s*([}\]])", r"\1", candidate_str)
                data = json.loads(candidate_str)
            except Exception as e:
                logger.error(f"Error parsing <tool_call>: {e}")
                continue
        items = data if isinstance(data, list) else [data]
        for item in items:
            if not isinstance(item, dict):
                continue
            name = item.get("name", "terminal")
            args = item.get("arguments") or item.get("parameters") or item.get("input") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except Exception:
                    pass
            tool_calls.append({
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(args) if isinstance(args, dict) else str(args)
                }
            })

    if not tool_calls:
        fenced_matches = re.findall(r"```(?:tool_call|json)\s*([{\[].*?[}\]])\s*```", text, re.DOTALL | re.IGNORECASE)
        for raw in fenced_matches:
            candidate_fenced = raw.strip()
            try:
                data = json.loads(candidate_fenced)
            except Exception:
                try:
                    candidate_fenced = re.sub(r"//.*$", "", candidate_fenced, flags=re.MULTILINE)
                    candidate_fenced = re.sub(r",\s*([}\]])", r"\1", candidate_fenced)
                    data = json.loads(candidate_fenced)
                except Exception:
                    continue
            items = data if isinstance(data, list) else [data]
            for item in items:
                if isinstance(item, dict) and "name" in item and ("arguments" in item or "parameters" in item or "input" in item):
                    name = item.get("name")
                    args = item.get("arguments") or item.get("parameters") or item.get("input") or {}
                    tool_calls.append({
                        "id": f"call_{uuid.uuid4().hex[:8]}",
                        "type": "function",
                        "function": {
                            "name": name,
                            "arguments": json.dumps(args) if isinstance(args, dict) else str(args)
                        }
                    })

    clean_text = re.sub(r"<tool[-_]calls?\s*>.*?</tool[-_]calls?>", "", text, flags=re.DOTALL | re.IGNORECASE)
    if tool_calls:
        clean_text = re.sub(r"```(?:tool_call|json)\s*[{\[].*?[}\]]\s*```", "", clean_text, flags=re.DOTALL | re.IGNORECASE)
        return tool_calls, clean_text.strip()
    return None, clean_text.strip() if clean_text.strip() else text.strip()

async def run_agy_turn(
    prompt: str,
    model_name: str = "gemini-3.8-flash-medium",
    reasoning_effort: str | None = None,
):
    selected_model, effort = resolve_model_and_effort(model_name, reasoning_effort)
    m = selected_model

    agy_binary = resolve_agy_bin()
    if not (Path(agy_binary).is_file() and os.access(agy_binary, os.X_OK)):
        logger.error("Antigravity binary not found or not executable: %s", agy_binary)
        yield ("error", f"Antigravity binary not found: {agy_binary}")
        return

    cmd = [
        agy_binary,
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--model", m,
        "--effort", effort,
        # Keep agy's own print-mode deadline aligned with the bridge deadline.
        # Otherwise agy can fail at its 5-minute default while this adapter is
        # still waiting for the configured longer timeout.
        "--print-timeout", AGY_PRINT_TIMEOUT,
        "--dangerously-skip-permissions",
    ]
    proc = None
    stderr_task = None

    async def drain_stderr():
        while proc is not None and proc.stderr is not None:
            line = await proc.stderr.readline()
            if not line:
                break
            logger.warning("agy stderr: %s", line.decode(errors="replace").rstrip())

    async def terminate_process():
        if proc is None:
            return
        pid = proc.pid
        if pid is None or proc.returncode is not None:
            return
        try:
            pgid = os.getpgid(pid)
            if pgid != os.getpgrp():
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, OSError):
            pass

        with contextlib.suppress(ProcessLookupError):
            proc.terminate()

        try:
            await asyncio.wait_for(proc.wait(), timeout=3)
        except (asyncio.TimeoutError, Exception):
            try:
                pgid = os.getpgid(pid)
                if pgid != os.getpgrp():
                    with contextlib.suppress(ProcessLookupError, PermissionError):
                        os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()

    try:
        start_new_session = sys.platform != "win32"
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=16 * 1024 * 1024,
            start_new_session=start_new_session,
        )
        stderr_task = asyncio.create_task(drain_stderr())

        msg = {
            "event": "user",
            "message": {"content": [{"type": "text", "text": prompt}]},
        }
        proc.stdin.write(json.dumps(msg).encode() + b"\n")
        await proc.stdin.drain()
        proc.stdin.close()

        async def read_events():
            full_content = []
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                try:
                    data = json.loads(line.decode(errors="replace").strip())
                except Exception:
                    continue

                event = data.get("event")
                if event == "step_update":
                    update = data.get("step_update", {})
                    if update.get("step_type") == "agent_response" and "text_delta" in update:
                        full_content.append(update["text_delta"])
                elif event == "result":
                    result = data.get("result")
                    result = result if isinstance(result, dict) else {}
                    error = result.get("error")
                    response = result.get("response") or "".join(full_content)
                    if proc.returncode is None:
                        with contextlib.suppress(Exception):
                            await asyncio.wait_for(proc.wait(), timeout=POST_RESULT_TIMEOUT_SECONDS)
                    if proc.returncode is not None and proc.returncode != 0:
                        error = error or f"agy exited with code {proc.returncode}"
                    elif proc.returncode is None and not (response and response.strip()):
                        error = error or "agy failed to terminate after result event"
                    elif not error and not (response and response.strip()):
                        error = "agy returned empty or unusable output"
                    return response, error
            collected = "".join(full_content)
            if proc.returncode is None:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(proc.wait(), timeout=POST_RESULT_TIMEOUT_SECONDS)
            if proc.returncode is None:
                return collected, "agy failed to terminate"
            if proc.returncode != 0:
                return collected, f"agy exited with code {proc.returncode}"
            if not collected.strip():
                return collected, "agy returned empty or unusable output"
            return collected, None

        if AGY_TIMEOUT_SECONDS is None:
            response, error = await read_events()
        else:
            response, error = await asyncio.wait_for(read_events(), timeout=AGY_TIMEOUT_SECONDS)
        if not error and not (response and response.strip()):
            error = "agy returned empty or unusable output"
        if error:
            logger.error("agy returned error: %s", error)
            yield ("error", f"Antigravity error: {error}")
            return
        yield ("done", response)
    except asyncio.TimeoutError:
        error = f"agy bridge timeout after {AGY_TIMEOUT_SECONDS}s"
        logger.error(error)
        yield ("error", f"Antigravity error: {error}")
    except Exception as exc:
        logger.exception("agy turn failed")
        yield ("error", f"Antigravity error: {exc}")
    finally:
        await terminate_process()
        if stderr_task is not None:
            stderr_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(stderr_task, timeout=2)

async def handle_models(request):
    created = int(time.time())
    return web.json_response({
        "object": "list",
        "data": [
            {"id": model, "object": "model", "created": created, "owned_by": "google-ai-pro"}
            for model in ALL_SUPPORTED_MODELS
        ],
    })


async def handle_model(request):
    model_id = request.match_info["model_id"]
    if normalize_model(model_id) is None:
        raise web.HTTPNotFound(text=f"model not found: {model_id}")
    return web.json_response({
        "id": model_id,
        "object": "model",
        "created": int(time.time()),
        "owned_by": "google-ai-pro",
    })

async def handle_chat_completions(request):
    try:
        body = await request.json()
    except Exception as exc:
        logger.warning("Failed to parse request JSON (%s): %s", type(exc).__name__, exc)
        return web.Response(status=400, text=f"Invalid JSON: {exc}")

    messages = body.get("messages", [])
    if not isinstance(messages, list) or not messages:
        return web.Response(status=400, text="messages must be a non-empty JSON array")
    tools = body.get("tools", [])
    if not isinstance(tools, list):
        return web.Response(status=400, text="tools must be a JSON array")
    stream = body.get("stream", False)
    model_req = body.get("model", "gemini-3.8-flash-medium")
    if not isinstance(model_req, str) or not model_req.strip():
        return web.Response(status=400, text="model must be a non-empty string")

    reasoning_effort_req = body.get("reasoning_effort")
    try:
        selected_model, effort = resolve_model_and_effort(model_req, reasoning_effort_req)
    except ValueError as exc:
        return web.json_response({
            "error": {
                "message": str(exc),
                "type": "invalid_request_error",
                "code": 400,
            }
        }, status=400)

    req_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    created = int(time.time())

    tool_names = [t.get("function", {}).get("name") for t in tools]
    logger.info(f"Hermes sent tools: {tool_names}, requested model: {model_req}, resolved: {selected_model}, effort: {effort}")
    prompt = build_prompt_with_tools(messages, tools)
    last_user_msg = ""
    for m in reversed(messages):
        if m.get("role") in ("user", "tool"):
            last_user_msg = f"{m.get('role')}: {m.get('content', '')}"
            break
    logger.info(f"Incoming turn (stream={stream}, model={model_req}, last='{last_user_msg[:60]}')")

    if stream:
        response = web.StreamResponse(
            status=200,
            reason="OK",
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            }
        )
        await response.prepare(request)

        # Background keepalive task emitting both SSE comments and empty delta chunks
        # to prevent client-side chunk-starvation watchdogs (like Hermes's 900s stale stream kill)
        parent_task = asyncio.current_task()

        async def stream_pinger():
            try:
                heartbeat_chunk = {
                    "id": req_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model_req,
                    "choices": [{"index": 0, "delta": {}, "finish_reason": None}],
                }
                heartbeat_bytes = f"data: {json.dumps(heartbeat_chunk)}\n\n".encode()
                elapsed = 0
                while True:
                    await asyncio.sleep(2)
                    if request.transport is not None and request.transport.is_closing():
                        logger.info("Client transport closing; cancelling turn task")
                        if parent_task and not parent_task.done():
                            parent_task.cancel()
                        break
                    elapsed += 2
                    if elapsed >= 15:
                        elapsed = 0
                        await response.write(b": ping\n\n")
                        await response.write(heartbeat_bytes)
            except (ClientConnectionError, ConnectionResetError, asyncio.CancelledError):
                logger.info("Client disconnected during stream ping; cancelling turn")
                if parent_task and not parent_task.done():
                    parent_task.cancel()
            except Exception as exc:
                logger.warning("Stream pinger exception: %s; cancelling turn", exc)
                if parent_task and not parent_task.done():
                    parent_task.cancel()

        pinger_task = asyncio.create_task(stream_pinger())
        turn = run_agy_turn(prompt, model_name=selected_model, reasoning_effort=effort)
        terminal_emitted = False
        try:
            async for kind, payload in turn:
                if kind == "error":
                    logger.error("Emitting stream error: %s", payload)
                    chunk = {
                        "id": req_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model_req,
                        "choices": [{"index": 0, "delta": {"role": "assistant", "content": f"⚠️ {payload}"}, "finish_reason": "stop"}],
                    }
                    await response.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    await response.write(b"data: [DONE]\n\n")
                    terminal_emitted = True
                    break
                if kind != "done":
                    continue
                complete_text = payload
                tool_calls, clean_text = parse_tool_calls(complete_text)
                if tool_calls:
                    logger.info("Emitting tool call: %s", tool_calls)
                    if clean_text:
                        content_chunk = {
                            "id": req_id,
                            "object": "chat.completion.chunk",
                            "created": created,
                            "model": model_req,
                            "choices": [{"index": 0, "delta": {"role": "assistant", "content": clean_text}, "finish_reason": None}],
                        }
                        await response.write(f"data: {json.dumps(content_chunk)}\n\n".encode())
                    streaming_tool_calls = []
                    for idx, tc in enumerate(tool_calls):
                        stc = dict(tc)
                        stc["index"] = idx
                        streaming_tool_calls.append(stc)
                    chunk = {
                        "id": req_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model_req,
                        "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": streaming_tool_calls}, "finish_reason": "tool_calls"}],
                    }
                    await response.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    terminal_emitted = True
                else:
                    final_reply = clean_text if clean_text else "Done."
                    logger.info("Emitting text reply: %s", final_reply[:60])
                    chunk = {
                        "id": req_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model_req,
                        "choices": [{"index": 0, "delta": {"role": "assistant", "content": final_reply}, "finish_reason": None}],
                    }
                    await response.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    stop_chunk = {
                        "id": req_id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": model_req,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    }
                    await response.write(f"data: {json.dumps(stop_chunk)}\n\n".encode())
                    terminal_emitted = True
                await response.write(b"data: [DONE]\n\n")
                break
        except (ClientConnectionError, ConnectionResetError, asyncio.CancelledError):
            logger.info("OpenAI client disconnected or cancelled before bridge response completed")
        except Exception as exc:
            if not terminal_emitted:
                logger.exception("Unexpected error in streaming turn")
                err_chunk = {
                    "id": req_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model_req,
                    "choices": [{"index": 0, "delta": {"role": "assistant", "content": f"⚠️ Antigravity error: {exc}"}, "finish_reason": "stop"}],
                }
                with contextlib.suppress(Exception):
                    await response.write(f"data: {json.dumps(err_chunk)}\n\n".encode())
                    await response.write(b"data: [DONE]\n\n")
                terminal_emitted = True
        finally:
            pinger_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await pinger_task
            await turn.aclose()

        return response
    else:
        full_text = ""
        is_error = False
        turn = run_agy_turn(prompt, model_name=selected_model, reasoning_effort=effort)
        try:
            async for kind, payload in turn:
                if kind == "error":
                    full_text = payload
                    is_error = True
                    break
                if kind == "done":
                    full_text = payload
                    break
        except Exception as exc:
            full_text = f"Antigravity error: {exc}"
            is_error = True
        finally:
            await turn.aclose()

        if is_error:
            message = {"role": "assistant", "content": f"⚠️ {full_text}"}
            return web.json_response({
                "id": req_id,
                "object": "chat.completion",
                "created": created,
                "model": model_req,
                "choices": [{
                    "index": 0,
                    "message": message,
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": max(1, len(prompt) // 4),
                    "completion_tokens": max(1, len(full_text) // 4),
                    "total_tokens": max(2, (len(prompt) + len(full_text)) // 4),
                },
            })

        tool_calls, clean_text = parse_tool_calls(full_text)
        finish_reason = "stop"
        if tool_calls:
            logger.info(f"Emitting tool call: {tool_calls}")
            message = {"role": "assistant", "content": clean_text or None, "tool_calls": tool_calls}
            finish_reason = "tool_calls"
        else:
            final_reply = clean_text if clean_text else "Done."
            logger.info(f"Emitting text reply: {final_reply[:60]}")
            message = {"role": "assistant", "content": final_reply}

        return web.json_response({
            "id": req_id,
            "object": "chat.completion",
            "created": created,
            "model": model_req,
            "choices": [{
                "index": 0,
                "message": message,
                "finish_reason": finish_reason
            }],
            "usage": {
                "prompt_tokens": max(1, len(prompt) // 4),
                "completion_tokens": max(1, len(full_text) // 4),
                "total_tokens": max(2, (len(prompt) + len(full_text)) // 4)
            }
        })


async def handle_health(request):
    current_bin = resolve_agy_bin()
    is_ok = Path(current_bin).is_file() and os.access(current_bin, os.X_OK)
    return web.json_response({
        "status": "ok" if is_ok else "degraded",
        "backend": current_bin,
        "models": list(MODEL_IDS),
        "timestamp": int(time.time()),
    })


def create_app() -> web.Application:
    app = web.Application(client_max_size=128 * 1024 * 1024)
    app.router.add_get("/v1/models", handle_models)
    app.router.add_get("/v1/models/{model_id}", handle_model)
    app.router.add_post("/v1/chat/completions", handle_chat_completions)
    app.router.add_get("/models", handle_models)
    app.router.add_get("/models/{model_id}", handle_model)
    app.router.add_post("/chat/completions", handle_chat_completions)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/v1/health", handle_health)
    return app


app = create_app()

if __name__ == "__main__":
    logger.info(f"Starting AgyBridge on http://{HOST}:{PORT}...")
    web.run_app(app, host=HOST, port=PORT)
