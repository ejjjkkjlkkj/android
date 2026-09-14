#!/usr/bin/env bash
set -euo pipefail

# Start the already-configured AccessibleAndroid GitHub Actions runner.
# This helper never registers, removes or reconfigures a runner. It only finds
# an existing installation and starts its installed service when available,
# otherwise it runs the configured runner in the foreground.

RUNNER_DIR="${RUNNER_DIR:-}"
MODE="${1:-auto}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

find_runner_dir() {
  local candidate

  if [[ -n "$RUNNER_DIR" ]]; then
    printf '%s\n' "$RUNNER_DIR"
    return 0
  fi

  for candidate in \
    "$HOME/actions-runner-android" \
    /home/admwsl2/actions-runner-android \
    /home/admws12/actions-runner-android; do
    if [[ -x "$candidate/run.sh" && -s "$candidate/.runner" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(find /home -maxdepth 3 -type f -path '*/actions-runner-android/run.sh' -perm -u+x -print 2>/dev/null | sort | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    dirname "$candidate"
    return 0
  fi

  return 1
}

runner_processes() {
  pgrep -af 'Runner\.(Listener|Worker)' 2>/dev/null || true
}

RUNNER_DIR="$(find_runner_dir)" || fail "configured actions-runner-android installation not found"
[[ -x "$RUNNER_DIR/run.sh" ]] || fail "run.sh missing in $RUNNER_DIR"
[[ -s "$RUNNER_DIR/.runner" ]] || fail "runner is not configured: $RUNNER_DIR/.runner missing"

cd "$RUNNER_DIR"

echo "RUNNER_DIR = $RUNNER_DIR"
echo "RUNNER_MODE = $MODE"

active="$(runner_processes)"
if [[ -n "$active" ]]; then
  echo "$active"
  echo "ANDROID_BUILD_RUNNER = ALREADY_RUNNING"
  exit 0
fi

start_service_if_available() {
  [[ -x ./svc.sh ]] || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1 || return 1

  # svc.sh status succeeds only when this runner has already been installed as
  # a service. Never auto-install a new service or alter runner registration.
  if sudo -n ./svc.sh status >/dev/null 2>&1; then
    sudo -n ./svc.sh start
    sleep 2
    if [[ -n "$(runner_processes)" ]]; then
      echo "ANDROID_BUILD_RUNNER = SERVICE_STARTED"
      return 0
    fi
  fi

  return 1
}

case "$MODE" in
  auto)
    if start_service_if_available; then
      exit 0
    fi
    echo "ANDROID_BUILD_RUNNER = FOREGROUND"
    exec ./run.sh
    ;;
  service)
    start_service_if_available || fail "runner service is not installed or could not be started"
    ;;
  foreground)
    echo "ANDROID_BUILD_RUNNER = FOREGROUND"
    exec ./run.sh
    ;;
  status)
    active="$(runner_processes)"
    if [[ -n "$active" ]]; then
      echo "$active"
      echo "ANDROID_BUILD_RUNNER = RUNNING"
      exit 0
    fi
    echo "ANDROID_BUILD_RUNNER = OFFLINE"
    exit 1
    ;;
  *)
    fail "mode must be auto, service, foreground or status"
    ;;
esac
