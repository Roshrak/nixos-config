# Hermes Agent + Antigravity Integration Decision Record

Date: 2026-09-02

## 1. Multi-Account Feasibility: BLOCKED BY UPSTREAM
- **Status:** Unsupported by upstream Antigravity CLI (`agy` 1.1.24).
- **Finding:** No official CLI mechanism exists for multiple named profiles, isolated credential stores, or programmatic identity switching. Keyring state is tied to a single user session without named profiles.
- **Policy:**
  - Configure Account A (`gemini-primary`) only.
  - Leave Account B completely unconfigured and untouched.
  - Automatic two-account failover is **BLOCKED BY UPSTREAM**.
  - Strict prohibition against `HOME` directory redirection, credential scraping, token copying, or unauthorized keyring manipulation.

## 2. Hermes-Antigravity Model Provider Integration: BLOCKED BY UPSTREAM
- **Status:** Unsupported in released Hermes Agent (revision `95f62ca3bfcfe788739ddd49fa6dd6b0c5568fc4`).
- **Finding:**
  - Hermes Agent provides Gemini API / AI Studio integrations and an optional Antigravity skill (for invoking `agy` as an autonomous coding subagent).
  - Hermes does NOT currently provide a native Antigravity model provider backend.
  - Hermes `external_process` provider plugin protocol is currently restricted to `copilot-acp` and does not provide a generic model transport for `agy`.
- **Policy:**
  - Adhere strictly to the approved architecture: do not deploy an unapproved plain-text wrapper, nested unrestricted AGY agent, deprecated consumer OAuth provider, or substitute Gemini API keys.
  - Execution halts at Phase 8 until a supported provider boundary exists upstream.
