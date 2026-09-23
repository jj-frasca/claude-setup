#!/usr/bin/env bash
# Regression test for the 2026-09-21 incident: token-refresh.sh logged "ok" for
# ~3 weeks while the Keychain credential was structurally dead (expiresAt=0,
# empty refreshToken), silently masking total auth failure. Asserts the DEAD
# path (empty/missing refreshToken) always reports "error", never "ok" —
# regardless of expiresAt — while confirming the legitimate "expired but
# refreshable" path still reports "ok" (that distinction is intentional, see
# token-refresh.sh's 2026-09-21 comment).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_REFRESH="$SCRIPT_DIR/token-refresh.sh"
FAILURES=0

FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_KEYCHAIN_JSON"
EOF
chmod +x "$FAKE_BIN/security"

run_case() {
  local name="$1" json="$2"
  local tmp_home; tmp_home="$(mktemp -d)"
  FAKE_KEYCHAIN_JSON="$json" PATH="$FAKE_BIN:$PATH" HOME="$tmp_home" \
    bash "$TOKEN_REFRESH" >/dev/null 2>&1
  local log="$tmp_home/.claude/_reports/cron.log"
  if [[ ! -f "$log" ]]; then
    echo "FAIL: $name — no cron.log written"
    FAILURES=$((FAILURES + 1))
    rm -rf "$tmp_home"
    return
  fi
  tail -1 "$log" | jq -r .status
  rm -rf "$tmp_home"
}

assert_status() {
  local name="$1" json="$2" expected="$3"
  local actual; actual="$(run_case "$name" "$json")"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name (status=$actual)"
  else
    echo "FAIL: $name — expected status=$expected, got status=$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

# Dead credential: epoch-zero expiry + empty refreshToken (the actual incident state).
assert_status "dead credential, epoch-zero expiry, empty refreshToken" \
  '{"claudeAiOauth":{"expiresAt":0,"refreshToken":""}}' \
  "error"

# Dead credential: epoch-zero expiry + missing refreshToken field entirely.
assert_status "dead credential, epoch-zero expiry, missing refreshToken" \
  '{"claudeAiOauth":{"expiresAt":0}}' \
  "error"

# Dead credential: future-looking expiry but no refresh token — still dead.
assert_status "dead credential, non-expired but empty refreshToken" \
  '{"claudeAiOauth":{"expiresAt":9999999999000,"refreshToken":""}}' \
  "error"

# Legitimate case: expired but has a live refresh token — CLI self-heals on next use.
assert_status "expired but alive (has refreshToken)" \
  '{"claudeAiOauth":{"expiresAt":1000,"refreshToken":"abc123"}}' \
  "ok"

# Legitimate case: not expired, has a live refresh token.
assert_status "valid, not expired" \
  '{"claudeAiOauth":{"expiresAt":9999999999000,"refreshToken":"abc123"}}' \
  "ok"

rm -rf "$FAKE_BIN"

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All token-refresh.sh regression tests passed"
