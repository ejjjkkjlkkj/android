[CmdletBinding()]
param(
    [string]$Distro = 'Debian',
    [string]$RunnerDir = '',
    [string]$Repository = 'ejjjkkjlkkj/android',
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe introuvable. WSL doit etre installe et disponible.'
}

$distros = @(wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Distro -notin $distros) {
    throw "Distribution WSL introuvable: $Distro. Disponibles: $($distros -join ', ')"
}

$mode = if ($Foreground) { 'foreground' } else { 'detached' }
$runnerDirArg = $RunnerDir

Write-Info "Distribution: $Distro"
Write-Info "Mode: $mode"
Write-Info "Repository: $Repository"

$linuxScript = @'
set -euo pipefail

requested_dir="${1:-}"
mode="${2:-detached}"
repository="${3:-ejjjkkjlkkj/android}"

find_runner_dir() {
  local candidate
  if [[ -n "$requested_dir" && -x "$requested_dir/run.sh" && -s "$requested_dir/.runner" ]]; then
    printf '%s\n' "$requested_dir"
    return 0
  fi

  for candidate in \
    "$HOME/actions-runner-android" \
    /home/admws12/actions-runner-android \
    /home/admwsl2/actions-runner-android; do
    if [[ -x "$candidate/run.sh" && -s "$candidate/.runner" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(find /home -maxdepth 3 -type f -path '*/actions-runner-android/run.sh' -perm -u+x -print 2>/dev/null | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] || return 1
  dirname "$candidate"
}

listener_running() {
  pgrep -af 'Runner\.Listener' >/dev/null 2>&1
}

report_github_runner_state() {
  local agent_name state_line status busy labels attempt

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

  agent_name="$(python3 - "$runner_dir/.runner" <<'PY'
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
  for attempt in $(seq 1 15); do
    state_line="$(gh api "repos/$repository/actions/runners" --paginate \
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
          echo 'GITHUB_RUNNER_STATE=ONLINE'
          return 0
        fi
        echo 'GITHUB_RUNNER_LABEL_ANDROID_BUILD=MISSING'
        echo 'GITHUB_RUNNER_STATE=ONLINE_LABEL_MISSING'
        return 4
      fi
    fi
    sleep 2
  done

  if [[ -n "$state_line" ]]; then
    echo 'GITHUB_RUNNER_STATE=VISIBLE_NOT_ONLINE'
    return 5
  fi

  echo 'GITHUB_RUNNER_STATE=NOT_VISIBLE_OR_API_UNAVAILABLE'
  return 0
}

finish_success() {
  local mode_name="$1" rc
  pgrep -af 'Runner\.Listener' || true
  echo "ANDROID_BUILD_RUNNER=$mode_name"
  report_github_runner_state || {
    rc=$?
    echo '[FAIL] Runner.Listener local actif mais runner GitHub android-build inutilisable.' >&2
    exit "$rc"
  }
  exit 0
}

runner_dir="$(find_runner_dir)" || {
  echo '[FAIL] installation actions-runner-android configuree introuvable' >&2
  exit 20
}

cd "$runner_dir"
echo "RUNNER_DIR=$runner_dir"

if listener_running; then
  finish_success 'ALREADY_RUNNING'
fi

workers="$(pgrep -af 'Runner\.Worker' 2>/dev/null || true)"
if [[ -n "$workers" ]]; then
  echo '[WARN] Runner.Worker detecte sans Runner.Listener actif:' >&2
  echo "$workers" >&2
fi

# svc.sh status returns non-zero when an installed service is stopped. Do not
# gate the start attempt on status success: try start directly, then prove that
# Runner.Listener really remains alive before accepting service mode.
if [[ -x ./svc.sh ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  echo 'RUNNER_SERVICE_STATUS_BEFORE='
  sudo -n ./svc.sh status 2>&1 || true

  service_log="$(mktemp)"
  if sudo -n ./svc.sh start >"$service_log" 2>&1; then
    cat "$service_log"
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
  else
    cat "$service_log" >&2 || true
    rm -f "$service_log"
    echo '[INFO] Service runner indisponible; fallback vers run.sh.' >&2
  fi
fi

if [[ "$mode" == 'foreground' ]]; then
  echo 'ANDROID_BUILD_RUNNER=FOREGROUND'
  exec ./run.sh
fi

mkdir -p _diag
log="$runner_dir/_diag/accessibleandroid-runner.log"
nohup ./run.sh >>"$log" 2>&1 </dev/null &
pid=$!
echo "RUNNER_PID=$pid"
echo "RUNNER_LOG=$log"

# A process that survives one short sleep can still die immediately after its
# initial GitHub handshake. Require a stable Listener observation instead.
stable=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  if listener_running; then
    stable=$((stable + 1))
    if (( stable >= 3 )); then
      finish_success 'DETACHED_STARTED'
    fi
  else
    stable=0
  fi
  sleep 2
done

echo '[FAIL] Runner.Listener ne reste pas actif apres le demarrage' >&2
tail -n 120 "$log" >&2 || true
exit 22
'@

$arguments = @('-d', $Distro, '--', 'bash', '-s', '--', $runnerDirArg, $mode, $Repository)
$linuxScript | & wsl.exe @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Echec du demarrage du runner WSL (exit $LASTEXITCODE)."
}

Write-Pass 'Runner AccessibleAndroid demarre ou deja actif et verifie quand GitHub API est disponible.'
Write-Host 'Le job GitHub en attente doit etre attribue automatiquement au runner labelise android-build.'
