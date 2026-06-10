# LocalLLMTrace — local-only LLM call logging schema

> **Status: future work. Do not implement without a human asking.**
> This file is a design anchor only. There is no trace-logging code today, and
> none should be written — no schema migration, no writer, no new dependencies —
> until a human explicitly asks for it. It can't be built yet anyway: there is no
> `StowerCore` LLM wrapper to trace. If you are an agent and a task seems to call
> for this, stop and confirm with the human first.

Design anchor for when `StowerCore`'s LLM wrapper gets wired up. **No
implementation yet.** This file fixes the schema now so the writer, when
built, mirrors the OpenTelemetry GenAI semantic conventions for forward
compatibility.

## Why local-only

No full-stack observability tool is zero-infrastructure: Langfuse needs
Postgres + ClickHouse, Phoenix and Helicone run their own containers, Logfire's
server is closed-source. For an always-local app the right model is Simon
Willison's `llm` CLI — one row per call in a local SQLite DB, no server. We
align column names with the OTel GenAI spec so the log can later be exported
to a real OTel backend without a migration.

## Schema (one row per LLM call, local SQLite via GRDB)

Column names mirror the OTel GenAI spec (all attributes currently at
Development stability) for forward compatibility:

| Column | OTel attribute |
|---|---|
| `trace_id` | span trace_id |
| `span_id` | span span_id |
| `operation_name` | `gen_ai.operation.name` |
| `provider` | `gen_ai.provider.name` |
| `request_model` | `gen_ai.request.model` |
| `response_model` | `gen_ai.response.model` |
| `input_tokens` | `gen_ai.usage.input_tokens` |
| `output_tokens` | `gen_ai.usage.output_tokens` |
| `duration_ms` | `gen_ai.client.operation.duration` (derived) |
| `temperature` | `gen_ai.request.temperature` |
| `finish_reasons` | `gen_ai.response.finish_reasons` (JSON array) |
| `input_messages` | `gen_ai.input.messages` (JSON, opt-in) |
| `output_messages` | `gen_ai.output.messages` (JSON, opt-in) |
| `tool_calls` | `gen_ai.tool.call.*` (JSON array) |
| `error_type` | `error.type` |
| `started_at` | span start_time |

No existing Swift library implements this directly — the writer is a thin
custom layer over GRDB.

## OTel alignment notes

- Required/conditionally-required attributes: `gen_ai.operation.name`
  (`chat`, `text_completion`, `embeddings`, `invoke_agent`, `execute_tool`),
  `gen_ai.provider.name`, `gen_ai.request.model`.
- `input_messages` / `output_messages` / `system_instructions` are **opt-in**
  and sensitive — off by default. Given the privacy rule in `AGENTS.md` ("do
  not use real Photos or Messages data in debug logs"), gate these behind an
  explicit developer toggle and never enable them on real user data.
- Deprecation: `gen_ai.prompt` / `gen_ai.completion` are removed; prompts and
  completions are captured via the `gen_ai.client.inference.operation.details`
  event with `gen_ai.input.messages` / `gen_ai.output.messages`.

## See also

- OTel GenAI semantic conventions: https://opentelemetry.io/docs/specs/semconv/gen-ai/
- Simon Willison's `llm` logging model: https://llm.datasette.io/en/stable/logging.html
- Parent research: Part VII, `/Users/emilykang/Documents/Projects/me/Research/signal-coding-swift-ai-guardrails-cited.md`
