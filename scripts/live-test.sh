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
SERVER=../mvCalendar
BASE=http://localhost:6100
SIM=${SIM:-CalendarLab-iPhone}

curl -fsS "$BASE/health" >/dev/null || { echo "mvCalendar isn't up at $BASE (cd $SERVER && docker compose up -d)"; exit 2; }
psql_cal() { docker exec cal-db psql -U cal -d cal -Atc "$1"; }
existing=$(psql_cal "SELECT count(*) FROM calendars WHERE owner_id IN ('$OWNER', '$PARTNER')")
[ "$existing" = "0" ] || { echo "refusing: an account already has a calendar locally"; exit 2; }

KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
mint() { (cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$1"); }

wipe() {
  psql_cal "DELETE FROM calendars WHERE owner_id IN ('$OWNER', '$PARTNER');
            DELETE FROM activity WHERE owner_id IN ('$OWNER', '$PARTNER');
            DELETE FROM calendar_prefs WHERE user_id IN ('$OWNER', '$PARTNER');" >/dev/null
}
trap wipe EXIT
trap "exit 130" INT TERM

# xcodebuild hands TEST_RUNNER_* variables to the test process (prefix removed).
TEST_RUNNER_CAL_LIVE_BASE=$BASE \
TEST_RUNNER_CAL_LIVE_OWNER=$OWNER TEST_RUNNER_CAL_LIVE_PARTNER=$PARTNER \
TEST_RUNNER_CAL_LIVE_OWNER_TOKEN=$(mint "$OWNER") TEST_RUNNER_CAL_LIVE_PARTNER_TOKEN=$(mint "$PARTNER") \
  xcodebuild test -scheme CalendarKit -destination "platform=iOS Simulator,name=$SIM" \
    -only-testing:CalendarKitTests/LiveTransportTests 2>&1 | grep -E "✔|✘|error:|Test run|recorded an issue"
