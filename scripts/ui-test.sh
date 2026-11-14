#!/usr/bin/env bash
# Runs CalendarLab's UI tests against the LOCAL mvCalendar as a TEST account, through the debug dev sign-in, and exports each
# screen's screenshot to /tmp/calendarlab-shots. Wipes the account after.
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/ui-test.sh <test-account-uuid>}
SERVER=../mvCalendar
SIM=${SIM:-CalendarLab-iPhone}
DD=${DD:-/tmp/calab-dd}   # build folder: give each resident their own
curl -fsS http://localhost:6100/health >/dev/null || { echo "mvCalendar isn't up"; exit 2; }
psql_cal() { docker exec cal-db psql -U cal -d cal -Atc "$1"; }
[ "$(psql_cal "SELECT count(*) FROM calendars WHERE owner_id = '$USER_ID'")" = "0" ] || { echo "refusing: $USER_ID already has a calendar locally"; exit 2; }
wipe() {
  psql_cal "DELETE FROM grants WHERE grantee_id = '$USER_ID';
            DELETE FROM calendars WHERE owner_id = '$USER_ID'; DELETE FROM activity WHERE owner_id = '$USER_ID';
            DELETE FROM user_state WHERE user_id = '$USER_ID'; DELETE FROM calendar_prefs WHERE user_id = '$USER_ID';
            DELETE FROM event_alerts WHERE user_id = '$USER_ID';" >/dev/null
}
trap wipe EXIT
trap "exit 130" INT TERM
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
RESULT=/tmp/calendarlab-ui.xcresult
rm -rf "$RESULT" /tmp/calendarlab-shots
cd Demo
TEST_RUNNER_CAL_DEV_TOKEN=$TOKEN TEST_RUNNER_CAL_DEV_USER=$USER_ID \
  xcodebuild test -project CalendarLab.xcodeproj -scheme CalendarLab \
    -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" \
    -resultBundlePath "$RESULT" 2>&1 | grep -E "Test Case .*(passed|failed)|error:|\*\* TEST" || true
xcrun xcresulttool export attachments --path "$RESULT" --output-path /tmp/calendarlab-shots >/dev/null 2>&1 || true
ls /tmp/calendarlab-shots 2>/dev/null | head -20
