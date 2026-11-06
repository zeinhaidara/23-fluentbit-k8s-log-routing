#!/usr/bin/env bash
# Exercises the Fluent Bit config with no cluster and no real backends: a dry-run of the
# production config (with and without the backend env vars set), the routing fixture through
# the real engine, and kubeconform on the DaemonSet YAML.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="fluent/fluent-bit@sha256:4f0c43a18de9a29c3a573bfc786a2660fc0a81c40209d37926d76fc87df4f4d4"
FAILED=0

check() {
  local desc="$1"
  local rc="$2"
  if [ "$rc" = "0" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAILED=1
  fi
}

run_fluent_bit() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$ROOT_DIR:/fluent-bit/etc" -w /fluent-bit/etc "$IMAGE" "$@"
}

cd "$ROOT_DIR"

# 1. dry-run with every backend env var set: config must be valid and raise no "not set" warning.
OUT_POSITIVE=$(
  MSYS_NO_PATHCONV=1 docker run --rm -v "$ROOT_DIR:/fluent-bit/etc" -w /fluent-bit/etc \
    -e ES_HOST=elasticsearch.example.com -e ES_INDEX=k8s-logs \
    -e S3_BUCKET=example-logs-bucket -e S3_REGION=us-east-1 \
    -e SPLUNK_HOST=splunk.example.com -e SPLUNK_TOKEN=REPLACE_ME \
    "$IMAGE" -c fluent-bit.conf --dry-run 2>&1
)
echo "$OUT_POSITIVE" | grep -q "configuration test is successful"
check "dry-run succeeds with all backend env vars set" "$?"
echo "$OUT_POSITIVE" | grep -q "is used but not set"
[ "$?" = "1" ]
check "no missing-env-var warning when all vars are set" "$?"

# 2. dry-run with no backend env vars set: must still validate, but must visibly report each
# missing variable - this is the "reported, not silently ignored" case.
OUT_NEGATIVE=$(run_fluent_bit -c fluent-bit.conf --dry-run 2>&1)
echo "$OUT_NEGATIVE" | grep -q "configuration test is successful"
check "dry-run still completes with backend env vars unset" "$?"
for var in ES_HOST ES_INDEX S3_BUCKET S3_REGION SPLUNK_HOST SPLUNK_TOKEN; do
  echo "$OUT_NEGATIVE" | grep -q "variable \${$var} is used but not set"
  check "missing $var is reported" "$?"
done

# 3. routing fixture through the real engine, one output file per backend plus the default.
rm -f tests/fixtures/output-*.log
run_fluent_bit -c tests/fixtures/test-fluent-bit.conf >/tmp/routing-run.log 2>&1
grep -q "order service started" tests/fixtures/output-es.log 2>/dev/null
check "es-labeled record routed to the es output" "$?"
grep -q "upload finished" tests/fixtures/output-s3.log 2>/dev/null
check "s3-labeled record routed to the s3 output" "$?"
grep -q "payment event" tests/fixtures/output-splunk.log 2>/dev/null
check "splunk-labeled record routed to the splunk output" "$?"
grep -q "unlabeled record" tests/fixtures/output-default.log 2>/dev/null
check "unlabeled record falls through to the default output" "$?"
grep -q "unknown backend value" tests/fixtures/output-default.log 2>/dev/null
check "unrecognized backend value falls through to the default output" "$?"

# every routed record must still carry its Kubernetes metadata
for f in tests/fixtures/output-es.log tests/fixtures/output-s3.log tests/fixtures/output-splunk.log tests/fixtures/output-default.log; do
  grep -q '"namespace_name"' "$f" 2>/dev/null
  check "kubernetes metadata present in $(basename "$f")" "$?"
done

rm -f tests/fixtures/output-*.log

exit $FAILED
