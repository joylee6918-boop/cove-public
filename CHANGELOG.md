# Changelog

## 2026-11-04 — geofencing and native activity queue (client build 86)

Incremental sanitized changes on the public branch, not private Git history or a
production deployment. No operational handoff, personal records, private media,
credentials or signing identity are imported.

### Included

- Default-off home/work geofences, phone-only centers, bounded durable event IDs,
  configuration/revocation fencing and initial/reconcile observations. One
  foreground fix establishes presence without requiring a boundary crossing;
  state reaches the backend and existing ordinary/Pulse inputs, not just the UI.
- Clear presence/monitor/upload status, direct system-settings permission button,
  and larger location/radius editing controls. System region monitoring is not
  continuous GPS and cannot guarantee immediate background delivery.
- Optional native App Intent recording with local-first persistence, independent
  recipient credentials/ACK/retries and a 7-day queued ingestion route. The legacy
  route retains its 10-minute window. A second compatible backend is optional and
  must be supplied by the operator; no system Screen Time/history import.
- Portable synthetic Swift model checks and queued route/store regressions.

### Publication verification

- **137 focused backend tests passed** (geofences, location, app events/queued
  ingestion, server/auth, notifications, files, health requests and voice regressions).
- **80 actual Swift model checks passed**: 29 geofence and 51 activity-queue cases.
- Unsigned generic iOS Simulator build succeeded: `com.example.cove`, build86,
  empty signing team. No simulator was launched or phone installed for publication.
- Initial backend command used an unavailable interpreter name and ran no tests;
  the corrected Python3.12 invocation completed the focused suite successfully.
- Public credential-pattern and personal-identifier/path/signing checks passed.
  Public-only permission defaults, optional-memory guards, generic identity and
  original synthetic audio fixtures were preserved. This is not a security audit
  certification or a claim that the older entire suite has been rerun.
- No real model, paid voice, Apple location, APNs or production request was made
  for publication. Hardware, background crossings, Shortcuts automation and
  natural model behavior need operator-authorized device acceptance.


## 2026-11-01 — public source refresh (client build 82)

Incremental update on the existing sanitized public history; no private repository
history, operational handoff, user records, private screenshots or signing assets
are imported. This is source publication, not an App Store release or deployment.

### Included

- Location cards from current GPS, MapKit search and explicit map selection;
  readable Apple-resolved addresses travel in the same chat/tool payload shown
  in the card. Eight-second bounded lookup, cancellation/late-result fencing,
  explicit missing-address fallback, original time/accuracy/source preserved.
- Independent default-off standing location grant; authorized ordinary/Pulse
  requests, one-shot foreground acquisition, optional background notification,
  owner-only routes, revision/device binding and at-most-one result continuation.
  No Always permission, continuous route collection or guaranteed background GPS.
- Bluetooth restoration of a previously selected device, system-owned reconnect,
  ACK-safe keepalive ordering and status deduplication; restoring a connection
  never replays an old hardware command. Still a Developer-only hardware adapter.
- Reduced redundant health/device state publication and per-bubble global-store
  observation, preserving explicit history highlighting and endpoint identity.
- Optional ElevenLabs / MiniMax selection with bounded responses, host-only
  configuration and durable paid-call receipts. Public default remains MiniMax;
  no personal voice ID, delivery tags or fixed personal seed is supplied.

### Public-specific safeguards retained

- Generic assistant/user labels, bundle identifiers and empty signing team.
- Operator-controlled `read-only` / `on-request` defaults; external memory remains
  opt-in. Generic public guidance and Developer-only disclosures are retained.
- Existing public icon and electronic-tone audio fixtures are unchanged; no new
  binary media is copied from the private tree. Private Pulse/travel services,
  personality material, deployment notes and configuration remain excluded.

### Verification

- **94 focused backend tests passed**: location, voice selection/providers,
  notifications, files/MCP, server and health-request regressions. An initial
  run exposed the fake app-server's outdated exact MCP inventory; adding the two
  new location tools to that fixture resolved it, and the full focused set passed.
- **31 actual Swift model/resolver checks passed** using a fake geocoder, plus
  manual/automatic message-wiring and backend address-preservation checks. All
  postal inputs are explicitly synthetic; no GPS or Apple geocoding request.
- Unsigned generic **iOS Simulator build succeeded** with Xcode27, bundle
  `com.example.cove`, build82 and no signing team. No simulator was launched and
  no device installation/UI or hardware acceptance was performed for this public
  build. Existing SDK deprecation warnings remain.
- Credential-pattern scan and private-identifier/path/signing review passed for
  the release tree. This is not an independent security audit. The previous full
  backend suite was not rerun; no all-tests-passing claim replaces its earlier
  limitations outside this focused scope.
- No real model message, paid TTS, APNs, real location, production deployment or
  existing-session restart was performed for publication.

## 2026-10-29 — public source refresh

Sanitized source snapshot aligned with the private client's Build 79 feature baseline. This is not an App Store/TestFlight release, a production deployment, or an import of private Git history.

### Included

- Full chat history search, message calendar, date/query intersections, literal highlights, historical navigation and explicit return to current chat. Full daily numbers and matching-month totals; message counts remain separate from external memory density.
- Durable attachments/outbox, incremental recovery, continuous sending, bounded history presentation, audio bubbles/waveforms, Markdown and native widgets.
- Fitness, personal ledger, virtual assistant wallet, user-controlled life-data sharing, phone system-action adapters and notification preferences.
- Optional memory/Pulse/Collar/travel/BLE/realtime/tmux adapters with explicit **Developer-only** dependencies and limits. No companion services, credentials, hardware, model weights or private voice baseline supplied.
- Updated self-hosting instructions, iOS 27 / Xcode 27 project, generic bundle identifiers and empty signing team.

### Public-release privacy changes

- Removed personal identity/relationship guidance, local account paths, private signing identifiers and operational deployment scripts from the export.
- External memory pool reading is opt-in; local chat evidence follows the operator's own data directory. No inherited personal standing authorization for external memory writes.
- Included only allowlisted source/assets. Rebuilt audio fixtures from electronic tones and silence, not recordings or speech. Private logs, databases, photos, keys, deployment notes and Git history are excluded.
- Updated the synthetic UTF-8 filename assertion after sanitization. Kept runtime behavior aligned with the source snapshot rather than introducing an unverified concurrency patch during publication.

### Verification and limits

- Public iOS application: unsigned generic Simulator build succeeded with Xcode 27. Existing SDK deprecation warnings remain. No claim of public-build device/UI acceptance or optional-service end-to-end verification.
- Initial backend run: 569 tests, 4 skipped, 1 failure and 2 errors. One error was missing optional NumPy/PyAV test dependencies; the synthetic filename assertion was corrected afterward. A concurrent wallet test also failed and remains an unresolved verification finding, not a claim of a production incident.
- A subsequent focused run executed 22 tests and ended with 2 errors. The test suite is **not reported as passing**. Further testing was stopped to keep this a source publication, not a production acceptance gate.
- Default secret-pattern scanning plus private-identifier/path review was performed before publication. This is not an independent security audit or a promise that arbitrary future configuration is safe.
- Full backend suite was not rerun after corrections. Optional offline voice-worker tests, native CLI/model smoke tests, physical hardware, HealthKit, APNs, paid TTS and realtime services were not accepted as working in this release.
- No production data, real model message, paid TTS call or test notification was used for validation; no server or existing assistant session was restarted.

The repository still has no project-level open-source license. Existing third-party notices remain applicable.
