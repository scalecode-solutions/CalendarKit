#!/usr/bin/env bash
# Runs CalendarLab's UI tests against the LOCAL mvCalendar as a TEST account, through the debug dev sign-in, and exports each
# screen's screenshot to /tmp/calendarlab-shots. Wipes the account after.
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/ui-test.sh <test-account-uuid>}
SERVER=../mvCalendar
SIM=${SIM:-CalendarLab27}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)   # by id: xcodebuild sometimes misses a sim by name
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
DD=${DD:-/tmp/calab-dd}   # build folder: give each resident their own
ONLY=${ONLY:-}            # one test method, e.g. ONLY=testEditorAndDetailTour (or Class/method)
# LAB_FRIEND=<friend uuid>: LabShellUITests' conversation (they skip without it).
# A bare method name is one of CalendarLabUITests'; a capitalized bare name is a class.
[[ -n "$ONLY" && "$ONLY" != */* && "$ONLY" != [A-Z]* ]] && ONLY=CalendarLabUITests/$ONLY
BASE=${BASE:-http://localhost:6100}   # a throwaway server: BASE=http://localhost:6101 CAL_DB=<its container>
curl -fsS "$BASE/health" >/dev/null || { echo "mvCalendar isn't up"; exit 2; }
psql_cal() { docker exec "${CAL_DB:-cal-db}" psql -U cal -d cal -Atc "$1"; }
[ "$(psql_cal "SELECT count(*) FROM calendars WHERE member_lo = '$USER_ID' OR member_hi = '$USER_ID'")" = "0" ] || { echo "refusing: $USER_ID already has a calendar locally"; exit 2; }
wipe() {
  # Every pair the account is in (events, labels, prefs and history go with it).
  psql_cal "DELETE FROM calendars WHERE member_lo = '$USER_ID' OR member_hi = '$USER_ID';" >/dev/null
}
trap wipe EXIT
trap "exit 130" INT TERM
# CONSENT_FROM=<friend uuid>: open the pair with that friend now, with the
# friend's intimate and cycle consents already on, so the privacy tests can
# reach "on for both" (0.8.0 design sprint; a test account can only turn on its own).
if [ -n "${CONSENT_FROM:-}" ]; then
  PAIR=$(python3 - "$USER_ID" "$CONSENT_FROM" <<'PY'
import hashlib, sys, uuid
a, b = sorted([uuid.UUID(sys.argv[1]).bytes, uuid.UUID(sys.argv[2]).bytes])
h = bytearray(hashlib.sha1(uuid.UUID('1cb2b0c2-a02e-4ef6-8d47-1f8f5c22fbfc').bytes + a + b).digest()[:16])
h[6] = (h[6] & 0x0F) | 0x50; h[8] = (h[8] & 0x3F) | 0x80
print(uuid.UUID(bytes=bytes(h)))
PY
)
  SIDE=$(python3 -c "import uuid,sys;print('lo' if uuid.UUID(sys.argv[1]).bytes < uuid.UUID(sys.argv[2]).bytes else 'hi')" "$CONSENT_FROM" "$USER_ID")
  psql_cal "INSERT INTO calendars (id, member_lo, member_hi, intimate_on_$SIDE, cycle_on_$SIDE)
            VALUES ('$PAIR', LEAST('$USER_ID'::uuid, '$CONSENT_FROM'::uuid), GREATEST('$USER_ID'::uuid, '$CONSENT_FROM'::uuid), now(), now());" >/dev/null
fi
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
RESULT=/tmp/calendarlab-ui.xcresult
rm -rf "$RESULT" /tmp/calendarlab-shots
cd Demo
TEST_RUNNER_CAL_DEV_TOKEN=$TOKEN TEST_RUNNER_CAL_DEV_USER=$USER_ID TEST_RUNNER_CONSENT_FROM=${CONSENT_FROM:-} TEST_RUNNER_LAB_FRIEND=${LAB_FRIEND:-} \
  xcodebuild test -project CalendarLab.xcodeproj -scheme CalendarLab \
    -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$DD" \
    -resultBundlePath "$RESULT" ${ONLY:+-only-testing:CalendarLabUITests/$ONLY} 2>&1 | grep -E "Test Case .*(passed|failed)|error:|\*\* TEST" || true
# Nothing ran (a misspelt ONLY) is a failure, not a pass (Leaf's catch).
RAN=$(xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('passedTests',0)+d.get('failedTests',0))" 2>/dev/null || echo 0)
[ "$RAN" != "0" ] || { echo "no tests ran: check ONLY ($ONLY)"; STATUS=1; }
xcrun xcresulttool export attachments --path "$RESULT" --output-path /tmp/calendarlab-shots >/dev/null 2>&1 || true
ls /tmp/calendarlab-shots 2>/dev/null | head -20
exit ${STATUS:-0}
