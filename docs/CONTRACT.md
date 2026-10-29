# Cove implementation contract

2026-10-29 public snapshot. SwiftUI, **iOS 27.0+ / Xcode 27**; Python 3.12+ backend. Pinned SwiftPM packages: MarkdownUI 2.4.1, swift-cmark 0.5.0, HighlighterSwift 3.1.0, WebRTC 150.0.0. This document is a contract overview, not a claim that optional services are supplied or verified.

## UI and state

- `CoveStore` is the main-actor observable store. Five tabs remain: home, pulse, chat, health, settings. Only explicit preview mode may display synthetic data.
- Connection credentials are user-entered, never packaged in the app. Cache/outbox state is isolated by endpoint. Preserve unsent drafts, acknowledged attachment IDs and original message identity across recovery.
- Each `ChatMessage` has its own conversation ID, timestamps, status, optional attachments, `readAt`, `isLiked`, and monotonic `revision`. Legacy records lacking additive fields must decode. Do not overwrite a newer revision with a late ACK or old page.
- Visible streaming/final content is separate from execution events and private reasoning. `littleThoughts` is an intentionally public aside, never a hidden reasoning transcript.
- Message search uses chat records, **not Ombre memory density**. Calendar totals count visible messages, including both user and assistant; display full counts. Query/month totals must come from the successful matching calendar response, not stale state.
- Search result navigation highlights literal query text, preserves historical reading position and provides an explicit return to current chat. Clearing highlighting and returning to the bottom are distinct actions. Endpoint/generation changes invalidate late navigation responses.
- Health timestamps/coverage come from actual data; absent data stays absent. Passive reading, sharing, standing permission, device mutations and active hardware measurement are separate authorization boundaries.
- Runtime-dependent surfaces must show unavailable/errors honestly. Developer-only entry points do not prove that a backend, vendor account or physical device is connected.

See the current Swift models and adapters in `ios/Cove/` for additive fields and exact decoding.

## HTTP envelope and routing

JSON uses camelCase and RFC3339 timestamps. Default listener is loopback `127.0.0.1:8796`; HTTPS is supplied by the operator. All owner endpoints require `Authorization: Bearer COVE_TOKEN`, except unauthenticated `GET /health`. App-event ingestion can instead use the separate narrowly scoped shortcuts token.

The authoritative route validation is `server/cove.py`; domain modules own their schemas. Unknown/invalid parameters must not silently widen privileges.

| Route family | Responsibility / implementation |
|---|---|
| `/health` | Process readiness only, no inference of model availability |
| `/v1/conversations` | Persistent conversation creation/listing and explicit thread mapping |
| `/v1/messages` | Durable message ACK, identity conflicts, incremental revisions, bounded history |
| `/v1/messages/search`, `/v1/messages/calendar` | Visible message query, date/month filters, cursor pagination and counts (`storage.py`) |
| `/v1/messages/reaction` | Set an explicit boolean like, idempotently; never enqueue another model turn |
| `/v1/interrupt` | Interrupt only the requested conversation's pending/active work |
| `/v1/attachments`, `/v1/stickers` | Authenticated inert bytes and separate user/assistant sticker libraries |
| `/v1/pulse`, `/v1/pulse/dashboard` | Read-only projection of separately supplied Pulse state |
| `/v1/usage` | Actual app-server account quota, not guessed or fabricated windows |
| `/v1/memory/calendar` | Optional Ombre bucket density, deliberately independent of chat counts |
| `/v1/health`, `/v1/health/history`, `/v1/health/uploads` | Validated shared snapshots and actual dated archives |
| `/v1/data-access` | Explicit persisted owner authorization for supported shared life data |
| `/v1/personal-ledger` and subroutes | Separate personal financial records and authorized command ACKs |
| `/v1/wallet` and subroutes | Assistant virtual wallet and owner-reviewed requests, no bank payments |
| `/v1/app-events` | Bounded paired App open/close event ingestion/readback, not Screen Time |
| `/v1/device-actions/...` | Scoped iPhone system capabilities, requests, confirmation and ACK |
| `/v1/devices` | APNs registration/removal for the operator's signed app |
| `/v1/terminal...` | Current-conversation execution log, actual model catalog and scoped approvals |
| `/v1/shell/...`, `/v1/tmux/...`, `/v1/realtime/...` | Experimental session-scoped protocols; see developer feature boundaries |
| `/v1/travel...`, `/v1/toy/...`, `/v1/aisay-wake` | Optional external adapters and explicitly authorized events, not default services |

Session handoff and other additive routes are likewise validated in `cove.py`; consult the source and corresponding synthetic route tests rather than guessing method/body fields.

## Durable messages and transport

`POST /v1/messages` accepts a caller-owned stable `id`, `conversationID`, text and optional reply/attachment/sticker/voice metadata. ACK follows a SQLite commit. Same ID plus canonical body returns the same record; a conflicting body/conversation returns 409. An uploaded file is not yet a sent message. Save each attachment ID before retrying.

`GET /v1/messages?conversationID=...&after=CURSOR` returns changed records and a cursor. Drain pages per conversation; global revisions are not message creation order. Do not skip changes from other conversations or fabricate retrospective read receipts. History/search pagination and incremental synchronization are different operations.

Runtime thread and turn IDs must match events precisely. New conversations get owned threads; resumption uses only the recorded mapping. Uncertain previously dispatched turns fail visibly after restart instead of blind replay. Queue acceptance does not mean input was read; `readAt` records actual turn-start binding, not comprehension.

Attachments are bounded (20 MiB per file; 29 MiB JSON request limit), authenticated and served with attachment disposition, `nosniff` and `no-store`. Preserve exact binary bytes. Supported image signatures and bounded valid text may enter model input; unsupported/truncated media is labeled honestly. HTML/SVG are not executed. Model exports require dedicated allowed roots and active-turn tool receipts, not phone credentials in model subprocesses.

## Execution and permissions

Default `read-only` sandbox / `on-request` approval remain operator-controlled. Changing the model for the next turn does not mutate the active turn. Pending approvals bind exact conversation/thread/turn and expire; stale callbacks cannot approve later operations. Successful pipe handoff is not proof of command success.

Execution logs are bounded, redacted and separate from chat messages. No arbitrary tool argument/result or private reasoning dump should become a visible assistant reply. Regex redaction cannot recognize every confidential prose output; safe host permissions remain necessary.

Phone-side confirmation/ACK, Bluetooth actual execution and third-party completion are different states. Pending or uncertain events must not be reported as successful. Revocation, timeout and retries must preserve idempotency and ownership.

## Data sharing and optional services

Health, App activity, personal ledger, external memory, Pulse, Collar, travel, TTS and APNs are not interchangeable permissions. Follow actual enabled grants and the relevant domain module's guards. Never invent standing authorization from a private persona prompt.

A model read timestamp means a scoped result was successfully handed to the runtime, not that the user saw or understood it. Deleting a shared snapshot does not delete Apple Health, historical messages or backups. External memory writes need configured tools, authorization and verified receipts; `queued`/`unknown` are not success.

See [DEVELOPER_FEATURES.md](DEVELOPER_FEATURES.md), [server configuration](../server/README.md), and [inline widgets](INLINE_WIDGETS.md). Regression tests use synthetic fixtures and isolated fake runtimes. Any real provider, device or model acceptance test requires separate explicit authorization.
