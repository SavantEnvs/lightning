#!/usr/bin/env bash
#
# mayhem/test.sh — RUN lightning's own unit tests (built with normal flags by mayhem/build.sh into
# mayhem/tests-bin/) and check known answers from the in-tree BOLT vectors through the built devtools.
# Each run-* binary asserts its own values and exits non-zero on failure; the devtools probes compare
# decoded BOLT11 / feature-bit / bech32-address / fp16 output against fixed expected text, so a build
# whose binaries do nothing (exit 0) fails here.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/mayhem/tests-bin"
[ -d "$BIN" ] || { echo "missing $BIN — mayhem/build.sh did not produce the test binaries" >&2; emit_ctrf lightning-unit 0 1; exit 1; }

passed=0; failed=0

# --- 1) the project's unit tests: each run-* binary is a self-asserting test program ---
# Several tests resolve their own path (argv[0]) or data relative to the source tree, so put the
# prebuilt binaries back where `make` would have left them (they are gitignored upstream) and run
# them from $SRC.
cp -a "$BIN"/. "$SRC"/ || { echo "cannot restore test binaries" >&2; emit_ctrf lightning-unit-and-kat 0 1; exit 1; }
TESTS=$(cd "$BIN" && find . -type f \( -name 'run-*' -o -name 'exp-run-*' \) | sort)
ntests=$(printf '%s\n' "$TESTS" | grep -c .)
if [ "$ntests" -lt 100 ]; then
  echo "FAIL: expected >=100 unit test binaries, found $ntests" >&2
  failed=$((failed + 1))
fi
results=$(printf '%s\n' "$TESTS" | xargs -r -P "$MAYHEM_JOBS" -I{} bash -c '
  if "{}" >/dev/null 2>"$0/$(echo {} | tr / _).err"; then echo "PASS {}"; else echo "FAIL {}"; fi' "${TMPDIR:-/tmp}")
passed=$((passed + $(printf '%s\n' "$results" | grep -c '^PASS ')))
nfail=$(printf '%s\n' "$results" | grep -c '^FAIL ')
failed=$((failed + nfail))
printf '%s\n' "$results" | grep '^FAIL ' | head -20

# --- 2) known-answer probes through the built devtools ---
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "PASS $1"
  else failed=$((failed + 1)); echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; fi
}

# BOLT11 spec example: 2500u => 250000000 msat, "1 cup coffee". (timestamp/expiry lines carry a
# local-time string, so they are left out.)
INV=lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh
check bolt11-decode "currency: bc
payee: 03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad
payment_hash: 0001020304050607080900010203040506070809000102030405060708090102
min_final_cltv_expiry: 18
msatoshi: 250000000
amount_msat: 250000000msat
description: '1 cup coffee'
payment_secret: 1111111111111111111111111111111111111111111111111111111111111111
features: 8 14
signature: 3045022100e59e3ffbd3945e4334879158d31e89b076dff54f3fa7979ae79df2db9dcaf58902206cbfe1a478b8d2307e92c88139464cb7e6ef26e414c4abe33337961ddc5e8ab1" \
  "$("$BIN/devtools/bolt11-cli" decode "$INV" 2>&1 | grep -v -e '^timestamp:' -e '^expiry:')"

check features-0x02aaa2 "option_data_loss_protect/odd (optional)
option_upfront_shutdown_script/odd (optional)
option_gossip_queries/odd (optional)
option_var_onion_optin/odd (optional)
option_gossip_queries_ex/odd (optional)
option_static_remotekey/odd (optional)
option_payment_secret/odd (optional)
option_basic_mpp/odd (optional)" "$("$BIN/devtools/features" 02aaa2 2>&1)"
check features-bit15 "option_payment_secret/odd (optional)" "$("$BIN/devtools/features" 8000 2>&1)"
check features-bit8 "option_var_onion_optin/even (compulsory)" "$("$BIN/devtools/features" 0100 2>&1)"

# BIP173/BIP350 segwit address vectors.
check encodeaddr "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7
bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y
bc1sw50qgdz25j
bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs
tb1qqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesrxh6hy
tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c
bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0" "$("$BIN/devtools/encodeaddr" 2>&1)"

check fp16-0x3c00 "fp16:0x3c00
min 131072
max 131199" "$("$BIN/devtools/fp16" fp16:0x3c00 2>&1)"
check fp16-0x1 "fp16:0x1
min 1
max 1" "$("$BIN/devtools/fp16" 1 2>&1)"

emit_ctrf lightning-unit-and-kat "$passed" "$failed"
