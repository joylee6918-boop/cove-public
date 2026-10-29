# Changelog

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
