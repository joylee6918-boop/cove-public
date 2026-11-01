# Location sharing and readable addresses

Added in the 2026-11-01 public source snapshot (client build 82). This document
contains no maintainer position, device identity, pairing information or private
deployment instructions. The app and backend are self-hosted by each operator.

## User experience

- Chat attachment menu → location: acquire a current position, search with MapKit,
  or select a point on the map. Sending uses the existing durable chat path and
  preserves the text draft. A selected destination is not proof the user is there.
- The user message is one complete `location_share` fenced JSON object. Only user
  messages render as received location cards; assistant-authored markup cannot
  masquerade as a phone GPS result.
- Current location and map-selected points use Apple reverse geocoding to obtain
  a readable name/address. Search results retain their supplied address. The same
  `name/address` fields are sent in chat/tool JSON and shown in the card and map.
- Lookup is best effort, bounded to eight seconds. Missing/failed results retain
  the original coordinate with an explicit unresolved-address label. Capture time,
  source and accuracy never change during lookup. Historical messages are not
  automatically geocoded or rewritten.
- Apple map/address services require connectivity and may use regional data
  providers/attributions. Displaying a map or resolving an address uses those
  services; the lookup is not an offline-only operation. No API key for a separate
  map SDK is bundled. Address data can be approximate or incomplete; do not infer
  an exact residence, room or verified attendance from a map label.

## Optional standing grant

The default is **off**. Settings → location sharing lets the user explicitly enable
an independent standing grant, in addition to the iOS When In Use permission.
Once enabled, an authorized model turn may request one new location without a
second per-request prompt. The grant is revision/device-bound and survives normal
app/server restarts; it is independent of health and other data-sharing grants.

The phone polls request status while foregrounded, but starts GPS only for a pending
request. Background requests use the operator's configured ordinary APNs alert;
opening the app allows acquisition and response. There is no Always permission,
background location mode, continuous route collection, or guaranteed locked-screen /
force-quit GPS. Revocation cancels acquisition/address lookup/upload locally and
retries server revocation after connectivity returns.

## Backend protocol

All routes below use the existing owner bearer credential:

- `GET /v1/location/status` → `{access, requests}`.
- `POST /v1/location/access`, `{enabled, revision, deviceID}` → `{access}`.
- `POST /v1/location/response`, `{requestID, revision, deviceID, snapshot}` or the
  same identity fields with `error` → `{ok, request}`.

Snapshots contain finite `latitude`, `longitude`, `accuracyMeters`, original
RFC3339 `capturedAt`, `source` (`current` or `selected` for a manual card), and
optional bounded `name/address`. Automatic responses require `source=current`.
Requests expire after ten minutes; invalid, future, stale, wrong-device and
old-grant responses are rejected. An identical accepted response retry is only
an ACK lookup, not a new acquisition or model continuation.

`location.sqlite3` is private instance data, not part of the repository. The model
cannot enable a grant or provide coordinates through a tool. Location names and
addresses are inert data, not instructions or automatic long-term memory entries.
Revoking sharing does not remove already delivered chat/context or backups.

## Model tools and continuation

- `cove_request_location({reason})` requests one fresh fix within an active ordinary
  or configured Pulse turn. `pending` does not mean a position was acquired.
- `cove_read_location({locationRequestID?})` reads an actual accepted response and
  its capture time, precision and stale status; absence/failure remains unknown.

The existing exact-turn FileBridge authorizes both tools. A result creates at most
one same-context internal continuation after the original turn is finished; it is
not fabricated user input. The continuation may read only its corresponding result
and cannot request again. If the original turn already read the result, no duplicate
continuation is sent. Unknown dispatch outcomes are not blindly replayed.

## Offline checks and limits

```sh
cd server
python3 -m unittest test_location_share test_notifications test_health_requests -v
```

On macOS with Xcode command-line tools:

```sh
python3 tools/test_location_address.py
```

The Swift harness uses the real source model/resolver with a fake geocoder and
explicitly synthetic postal data. It does not read GPS or contact Apple. The public
release's focused tests/build do not establish actual GPS, geocoder coverage,
permission prompts, APNs, physical UI or a real model tool roundtrip. Those require
an operator-authorized check on their own device/backend. See `CHANGELOG.md`.
