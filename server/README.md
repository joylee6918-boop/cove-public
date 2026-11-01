# Cove self-hosted backend

2026-11-01 public snapshot · **Python 3.12+** · one owner per instance.

Core chat uses Python's standard library, SQLite and a separately installed/authenticated Codex CLI. Optional integrations are not bundled services. Read [Developer-only boundaries](../docs/DEVELOPER_FEATURES.md) before enabling them.

## Start

1. Create a dedicated low-privilege Unix account, workspace and `CODEX_HOME`. Authenticate your own Codex account there. Do not borrow another running assistant's session, login or private identity.
2. Copy `.env.example` to an untracked private `.env`, generate a unique token (at least 24 random characters), and set absolute data/workspace paths. Create those directories with private permissions. Replace the example value; do not deploy it literally.
3. Export the environment and start from this directory:

```sh
chmod 600 .env
set -a
. ./.env
set +a
python3 cove.py
```

The default listener is `127.0.0.1:8796`. Use your own HTTPS reverse proxy for phone access, with at least a 29 MiB request-body allowance for Base64 attachments. Do not expose the bare port or share the owner token. `GET /health` is process readiness, not evidence of model connectivity; authenticated `/v1/usage` reads actual app-server account information without sending a model turn.

`cove.service` is an illustrative systemd template, not an installer. Adjust its user, paths and Python interpreter; keep `/etc/cove/cove.env` mode 0600. The service account must own its own Codex login and workspace. Running it as a new user does not inherit another user's login.

## Configuration

| Setting | Meaning |
|---|---|
| `COVE_TOKEN` | Private owner credential; one shared trust domain, not per-user accounts |
| `COVE_WORKSPACE` | Dedicated operator-configured assistant workspace |
| `CODEX_HOME` | Optional explicit isolated Codex configuration/login directory |
| `COVE_DATA_DIR` | Persistent private data directory; default `~/.local/share/cove` |
| `COVE_CODEX_COMMAND` | Default `codex app-server`; must resolve for the service account |
| `COVE_MODEL`, `COVE_EFFORT` | Account-supported model / effort; empty model uses the host default |
| `COVE_SANDBOX`, `COVE_APPROVAL_POLICY` | Keep safe defaults `read-only` / `on-request`; review any widening |
| `COVE_APPROVAL_TIMEOUT`, `COVE_TURN_TIMEOUT` | Pending approval / model turn deadlines |
| `COVE_EXPORT_ROOTS` | Colon-separated dedicated file-export roots; empty disables path exports |
| `COVE_RUNTIME` | `app-server` by default; `tmux` is an explicitly selected experimental alternative |
| `COVE_SHORTCUTS_TOKEN` | Optional separate write-only App-event credential, 32–256 ASCII characters |
| `COVE_PULSE_PATH` | Optional read-only compatible Pulse snapshot; no service is launched |
| `COVE_OB_BUCKETS_PATH`, `COVE_MEMORY_DB` | Optional operator-owned external memory data, not included |
| `COVE_CHAT_DB` | Optional explicit chat evidence DB; otherwise follows this instance's data directory |
| `COVE_COLLAR_URL`, `COVE_COLLAR_TOKEN` | Optional independent Collar bridge |
| `COVE_TRAVEL_TOKEN_FILE` | Optional token file for a separately implemented loopback travel service |

Additional Apple, TTS, speech-model and runtime settings live in their source modules. Never store real values in these documents. The public default project uses example bundle IDs and no signing team; APNs must match **your** actual signed app.

Install optional APNs/WeatherKit cryptographic dependencies in your own virtual environment:

```sh
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements-apns.txt
```

## Optional paid speech

`cove_send_voice` accepts `text` and optional `voice` (`minimax` / `elevenlabs`).
Omission follows `COVE_VOICE_DEFAULT`, which remains `minimax` unless explicitly
changed. MiniMax uses `COVE_MINIMAX_API_KEY` / `COVE_MINIMAX_VOICE_ID`. ElevenLabs
requires both `COVE_ELEVENLABS_KEY_PATH` and `COVE_ELEVENLABS_VOICE_ID`; the key file
must be an absolute regular file owned by the service uid, mode0600, not a symlink.
No voice ID, private delivery instructions or fixed personal seed is bundled.
Check provider/model availability and cost in your own account before enabling it.

Keys stay host-side and are excluded from the app-server child environment.
Responses are bounded MP3 bytes; redirects are rejected. The durable tool receipt
is written before provider IO. Unknown/failed outcomes do not retry with changed
text or another provider, avoiding a second paid attempt hidden behind a fallback.

## Durability and upgrades

- SQLite uses WAL, foreign keys, durable commits and a single-owner data-directory lock. Keep runtime directories private. Back up consistently using SQLite backup tooling; copying a live main DB without its WAL is not a safe backup.
- A user-message ID and canonical body commit before ACK. Matching retries return the same message; conflicting retries return 409. Persist uploaded attachment IDs before retrying a message.
- Turns are serialized through a durable queue. Each Cove conversation maps to its own recorded thread; the adapter does not select another application's latest thread. Streaming notifications must match explicit thread/turn IDs.
- Claimed/dispatched work interrupted by a process restart is uncertain and visibly fails rather than blindly replaying. Queued, never-started work may run. A new user retry requires a new message ID after reviewing the failed result.
- Polling revisions are distinct from creation order. Drain pages per conversation; do not let a late ACK or old poll overwrite a newer cached message revision. A receipt means input reached a real model turn, not that the model understood it.
- Local continuation preserves chat history while changing a bound runtime thread. Token thresholds in `auto_rollover.py` are model-specific tuning, not universal limits. External OB memory is optional and separately authorized; a queued memory write is not proof of successful storage.
- Before replacing an older deployment, back up its complete data directory, review schema/protocol changes and test a copy with an isolated fake runtime. No production deployment or migration is performed by this repository.

## Privacy and permission boundaries

All owner routes except readiness require the owner bearer token. App-event ingestion additionally accepts its separately scoped token; that token cannot read chats or operate other routes.

HealthKit itself remains on iOS. Shared snapshots retain actual capture/sample/coverage timestamps. UI reads do not mark data as model-read. Persistent data sharing must be explicitly enabled by the owner and can cover personal-ledger commands; it does not authorize banking or arbitrary device control. Deletion removes the application copy, not Apple Health, historical messages, upstream context or backups.

Model file tools use an adapter-owned loopback callback with a separate scoped capability and checks against the active turn and actual tool event. Empty export roots disable path access. Broad roots, traversal, symlinks, hardlinks and special files are refused; binary attachments remain inert and cannot be described as read merely because upload succeeded.

Default execution is read-only with on-request approvals. The execution-log console, restricted Shell and experimental native tmux console are distinct capabilities. They are not multi-user isolation. Keep the host user unprivileged; never connect an experimental terminal to another active conversation. Arbitrary confidential output cannot be reliably redacted by pattern matching alone.

Push happens after durable reply commit and is best effort; polling is authoritative. Notification-content preview is an explicit user setting, not always enabled. Configuring TTS, proactive wake services, travel images or real model tests may incur costs and transmit content to third parties. This snapshot sends no such traffic as an installation step.

## Verification

```sh
python3 -m unittest discover -v
```

Tests use temporary databases, synthetic fixtures, local HTTP and deterministic fake app-server processes. Native Codex smoke tests require explicit opt-in and a deliberately replaced nonexistent binary placeholder; never run them against a real user's existing session. Optional encryption/ffmpeg/tmux dependencies may affect skips. No test result establishes physical hardware, HealthKit, APNs, realtime or paid provider availability.

Release-specific results and limitations are in [CHANGELOG.md](../CHANGELOG.md). The app-server protocol evolves; validate your installed CLI against the adapter and [official protocol documentation](https://developers.openai.com/codex/app-server/). Do not silently remove rejected tools, widen permissions, switch models or substitute another thread to hide incompatibility.
