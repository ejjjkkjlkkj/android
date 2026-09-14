[CmdletBinding()]
param(
    [string]$Distro = 'Debian',
    [string]$RunnerDir = '',
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

$linuxScript = @'
set -euo pipefail

requested_dir="${1:-}"
mode="${2:-detached}"

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

runner_dir="$(find_runner_dir)" || {
  echo '[FAIL] installation actions-runner-android configuree introuvable' >&2
  exit 20
}

cd "$runner_dir"
echo "RUNNER_DIR=$runner_dir"

active="$(pgrep -af 'Runner\.(Listener|Worker)' 2>/dev/null || true)"
if [[ -n "$active" ]]; then
  echo "$active"
  echo 'ANDROID_BUILD_RUNNER=ALREADY_RUNNING'
  exit 0
fi

if [[ -x ./svc.sh ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  if sudo -n ./svc.sh status >/dev/null 2>&1; then
    sudo -n ./svc.sh start
    sleep 3
    if pgrep -af 'Runner\.(Listener|Worker)' >/dev/null 2>&1; then
      echo 'ANDROID_BUILD_RUNNER=SERVICE_STARTED'
      exit 0
    fi
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
sleep 4

if ! kill -0 "$pid" 2>/dev/null; then
  echo '[FAIL] le runner s est arrete pendant le demarrage' >&2
  tail -n 80 "$log" >&2 || true
  exit 21
fi

if ! pgrep -af 'Runner\.(Listener|Worker)' >/dev/null 2>&1; then
  echo '[FAIL] processus GitHub Actions runner non detecte' >&2
  tail -n 80 "$log" >&2 || true
  exit 22
fi

echo 'ANDROID_BUILD_RUNNER=DETACHED_STARTED'
'@

$arguments = @('-d', $Distro, '--', 'bash', '-s', '--', $runnerDirArg, $mode)
$linuxScript | & wsl.exe @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Echec du demarrage du runner WSL (exit $LASTEXITCODE)."
}

Write-Pass 'Runner AccessibleAndroid demarre ou deja actif.'
Write-Host 'Le job GitHub en attente doit etre attribue automatiquement au runner labelise android-build.'
