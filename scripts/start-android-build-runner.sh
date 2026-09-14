#!/usr/bin/env bash
set -euo pipefail

# Start the already-configured AccessibleAndroid GitHub Actions runner.
# This helper never registers, removes or reconfigures a runner. It only finds
# an existing installation and starts its installed service when available,
# otherwise it runs the configured runner in the foreground.

RUNNER_DIR="${RUNNER_DIR:-}"
MODE="${1:-auto}"
REPOSITORY="${REPOSITORY:-ejjjkkjlkkj/android}"

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

listener_running() {
  pgrep -af 'Runner\.Listener' >/dev/null 2>&1
}

listener_processes() {
  pgrep -af 'Runner\.Listener' 2>/dev/null || true
}

worker_processes() {
  pgrep -af 'Runner\.Worker' 2>/dev/null || true
}

report_github_runner_state() {
  local agent_name state_line status busy labels

  if ! command -v gh >/dev/null 2>&1; then
    echo 'GITHUB_RUNNER_STATE=SKIP_NO_GH'
    return 0
  fi
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    echo 'GITHUB_RUNNER_STATE=SKIP_GH_NOT_AUTHENTICATED'
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'GITHUB_RUNNER_STATE=SKIP_NO_PYTHON3'
    return 0
  fi

  agent_name="$(python3 - "$RUNNER_DIR/.runner" <<'PY'
import json
import pathlib
import sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
    print(data.get('agentName', ''))
except Exception:
    print('')
PY
)"
  if [[ -z "$agent_name" ]]; then
    echo 'GITHUB_RUNNER_STATE=SKIP_AGENT_NAME_UNKNOWN'
    return 0
  fi

  echo "GITHUB_RUNNER_NAME=$agent_name"
  state_line=''
  for _ in 1 2 3 4 5 6; do
    state_line="$(gh api "repos/$REPOSITORY/actions/runners" --paginate \
      --jq ".runners[] | select(.name == \"$agent_name\") | [.status, (.busy|tostring), ([.labels[].name] | join(\",\"))] | @tsv" \
      2>/dev/null | head -n 1 || true)"
    if [[ -n "$state_line" ]]; then
      IFS=$'\t' read -r status busy labels <<<"$state_line"
      echo "GITHUB_RUNNER_STATUS=$status"
      echo "GITHUB_RUNNER_BUSY=$busy"
      echo "GITHUB_RUNNER_LABELS=$labels"
      if [[ "$status" == 'online' ]]; then
        if [[ ",$labels," == *,android-build,* ]]; then
          echo 'GITHUB_RUNNER_LABEL_ANDROID_BUILD=PASS'
        else
          echo 'GITHUB_RUNNER_LABEL_ANDROID_BUILD=MISSING'
        fi
        echo 'GITHUB_RUNNER_STATE=ONLINE'
        return 0
      fi
    fi
    sleep 2
  done

  if [[ -n "$state_line" ]]; then
    echo 'GITHUB_RUNNER_STATE=VISIBLE_NOT_ONLINE'
  else
    echo 'GITHUB_RUNNER_STATE=NOT_VISIBLE_OR_API_UNAVAILABLE'
  fi
}

finish_success() {
  local mode_name="$1"
  listener_processes
  echo "ANDROID_BUILD_RUNNER=$mode_name"
  report_github_runner_state
  exit 0
}

RUNNER_DIR="$(find_runner_dir)" || fail "configured actions-runner-android installation not found"
[[ -x "$RUNNER_DIR/run.sh" ]] || fail "run.sh missing in $RUNNER_DIR"
[[ -s "$RUNNER_DIR/.runner" ]] || fail "runner is not configured: $RUNNER_DIR/.runner missing"

cd "$RUNNER_DIR"

echo "RUNNER_DIR=$RUNNER_DIR"
echo "RUNNER_MODE=$MODE"
echo "RUNNER_REPOSITORY=$REPOSITORY"

if listener_running; then
  finish_success 'ALREADY_RUNNING'
fi

workers="$(worker_processes)"
if [[ -n "$workers" ]]; then
  echo 'WARN: Runner.Worker detected without an active Runner.Listener:' >&2
  echo "$workers" >&2
fi

start_service_if_available() {
  local service_log

  [[ -x ./svc.sh ]] || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1 || return 1

  # An installed but stopped systemd service commonly makes `svc.sh status`
  # return non-zero. Always show status, then attempt start directly. The only
  # accepted success condition is a stable Runner.Listener process.
  echo 'RUNNER_SERVICE_STATUS_BEFORE='
  sudo -n ./svc.sh status 2>&1 || true

  service_log="$(mktemp)"
  if ! sudo -n ./svc.sh start 2>&1 | tee "$service_log"; then
    rm -f "$service_log"
    return 1
  fi
  rm -f "$service_log"

  for _ in 1 2 3 4 5 6; do
    if listener_running; then
      sleep 2
      if listener_running; then
        finish_success 'SERVICE_STARTED'
      fi
    fi
    sleep 2
  done

  return 1
}

case "$MODE" in
  auto)
    if start_service_if_available; then
      exit 0
    fi
    echo 'ANDROID_BUILD_RUNNER=FOREGROUND'
    exec ./run.sh
    ;;
  service)
    start_service_if_available || fail "runner service is not installed or could not be started"
    ;;
  foreground)
    echo 'ANDROID_BUILD_RUNNER=FOREGROUND'
    exec ./run.sh
    ;;
  status)
    if listener_running; then
      listener_processes
      echo 'ANDROID_BUILD_RUNNER=RUNNING'
      report_github_runner_state
      exit 0
    fi
    workers="$(worker_processes)"
    if [[ -n "$workers" ]]; then
      echo "$workers" >&2
      echo 'ANDROID_BUILD_RUNNER=ORPHAN_WORKER'
      exit 3
    fi
    echo 'ANDROID_BUILD_RUNNER=OFFLINE'
    exit 1
    ;;
  *)
    fail "mode must be auto, service, foreground or status"
    ;;
esac
