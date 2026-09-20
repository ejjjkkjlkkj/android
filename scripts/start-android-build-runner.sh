#!/usr/bin/env bash
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-android}"
RUNNER_LOG="${RUNNER_LOG:-$HOME/github-android-runner.log}"
START_WAIT_SECONDS="${START_WAIT_SECONDS:-8}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -d "$RUNNER_DIR" ]] || fail "runner directory not found: $RUNNER_DIR"
[[ -x "$RUNNER_DIR/run.sh" ]] || fail "run.sh not found or not executable: $RUNNER_DIR/run.sh"
[[ -f "$RUNNER_DIR/.runner" ]] || fail "runner is not configured: $RUNNER_DIR/.runner is missing"

cd "$RUNNER_DIR"

echo "RUNNER_DIR=$RUNNER_DIR"
echo "RUNNER_LOG=$RUNNER_LOG"

runner_process() {
  pgrep -af '[R]unner\.Listener|[r]unsvc\.sh' || true
}

if [[ -n "$(runner_process)" ]]; then
  echo "RUNNER_PROCESS = ALREADY_RUNNING"
  runner_process
  exit 0
fi

service_started=0
if [[ -x ./svc.sh ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  echo "==> Trying configured GitHub Actions service"
  set +e
  sudo -n ./svc.sh start
  svc_status=$?
  set -e
  if [[ "$svc_status" -eq 0 ]]; then
    service_started=1
  else
    echo "WARNING: svc.sh start returned $svc_status; falling back to run.sh" >&2
  fi
fi

if [[ "$service_started" -eq 0 ]]; then
  echo "==> Starting runner interactively in background"
  nohup ./run.sh >>"$RUNNER_LOG" 2>&1 &
  echo "$!" > "$HOME/github-android-runner.pid"
fi

sleep "$START_WAIT_SECONDS"

if [[ -z "$(runner_process)" ]]; then
  echo "RUNNER_LOG_TAIL_BEGIN" >&2
  tail -n 120 "$RUNNER_LOG" >&2 2>/dev/null || true
  echo "RUNNER_LOG_TAIL_END" >&2
  fail "Runner.Listener did not start"
fi

echo "RUNNER_PROCESS = PASS"
runner_process

if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-pager --full status 'actions.runner.ejjjkkjlkkj-android.service' 2>/dev/null || true
fi

echo "ANDROID_BUILD_RUNNER = STARTED"
echo "Expected GitHub labels: self-hosted, Linux, X64, android-build"
