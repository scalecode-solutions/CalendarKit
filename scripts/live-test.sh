#!/usr/bin/env bash
# Runs CalendarKit's live transport tests against the LOCAL mvCalendar stack
# (../mvCalendar, docker compose up), as two TEST accounts that are friends in
# the local social graph. Never a real person's account.
#
#   scripts/live-test.sh <owner-uuid> <partner-uuid>
#
# Refuses if either account already has a calendar in the local database
# (that would be someone's data); wipes both accounts' calendar data when done.
set -euo pipefail
cd "$(dirname "$0")/.."
OWNER=${1:?usage: scripts/live-test.sh <owner-uuid> <partner-uuid> (test accounts)}
PARTNER=${2:?usage: scripts/live-test.sh <owner-uuid> <partner-uuid> (test accounts)}
SERVER=${SERVER:-../mvCalendar}
BASE=${BASE:-http://localhost:6100}   # a throwaway server: BASE=http://localhost:6101 CAL_DB=<its container>
SIM=${SIM:-CalendarLab27}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)   # by id: xcodebuild sometimes misses a sim by name
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }

curl -fsS "$BASE/health" >/dev/null || { echo "mvCalendar isn't up at $BASE (cd $SERVER && docker compose up -d)"; exit 2; }
psql_cal() { docker exec "${CAL_DB:-cal-db}" psql -U cal -d cal -Atc "$1"; }
existing=$(psql_cal "SELECT count(*) FROM calendars WHERE member_lo IN ('$OWNER', '$PARTNER') OR member_hi IN ('$OWNER', '$PARTNER')")
[ "$existing" = "0" ] || { echo "refusing: an account already has a calendar locally"; exit 2; }

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
mint() { (cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$1"); }

wipe() {
  # Every pair either is in (their events, labels, prefs and history go with it).
  psql_cal "DELETE FROM calendars WHERE member_lo IN ('$OWNER', '$PARTNER') OR member_hi IN ('$OWNER', '$PARTNER');" >/dev/null
}
trap wipe EXIT
trap "exit 130" INT TERM

# xcodebuild hands TEST_RUNNER_* variables to the test process (prefix removed).
TEST_RUNNER_CAL_LIVE_BASE=$BASE \
TEST_RUNNER_CAL_LIVE_OWNER=$OWNER TEST_RUNNER_CAL_LIVE_PARTNER=$PARTNER \
TEST_RUNNER_CAL_LIVE_OWNER_TOKEN=$(mint "$OWNER") TEST_RUNNER_CAL_LIVE_PARTNER_TOKEN=$(mint "$PARTNER") \
  xcodebuild test -scheme CalendarKit -destination "platform=iOS Simulator,id=$SIM_ID" \
    -only-testing:CalendarKitTests/LiveTransportTests 2>&1 | grep -E "✔|✘|error:|Test run|recorded an issue"
