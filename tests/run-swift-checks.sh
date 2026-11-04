#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cove-model-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc "$root/ios/Cove/GeofenceModels.swift" "$root/tests/swift/GeofenceChecks.swift" -o "$work/geofence"
"$work/geofence"
swiftc "$root/ios/Cove/AppActivityQueue.swift" "$root/tests/swift/AppActivityQueueChecks.swift" -o "$work/activity"
"$work/activity"
