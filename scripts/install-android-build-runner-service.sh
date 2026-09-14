#!/usr/bin/env bash
set -euo pipefail

REQUESTED_DIR="${1:-${RUNNER_DIR:-}}"
CONFIGURE_NEEDRESTART="${CONFIGURE_NEEDRESTART:-1}"

find_runner_dir() {
  local candidate

  if [[ -n "$REQUESTED_DIR" && -x "$REQUESTED_DIR/run.sh" && -x "$REQUESTED_DIR/svc.sh" && -s "$REQUESTED_DIR/.runner" ]]; then
    printf '%s\n' "$REQUESTED_DIR"
    return 0
  fi

  for candidate in \
    "$HOME/actions-runner-android" \
    /home/admwsl2/actions-runner-android \
    /home/admws12/actions-runner-android; do
    if [[ -x "$candidate/run.sh" && -x "$candidate/svc.sh" && -s "$candidate/.runner" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(find /home -maxdepth 3 -type f -path '*/actions-runner-android/svc.sh' -perm -u+x -print 2>/dev/null | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] || return 1
  dirname "$candidate"
}

listener_running() {
  pgrep -af 'Runner\.Listener' >/dev/null 2>&1
}

runner_dir="$(find_runner_dir)" || {
  echo '[FAIL] installation actions-runner-android configuree introuvable' >&2
  exit 20
}

cd "$runner_dir"
echo "RUNNER_DIR=$runner_dir"

[[ -s .runner ]] || {
  echo '[FAIL] .runner absent: le runner doit deja etre enregistre avant installation du service.' >&2
  exit 21
}

command -v systemctl >/dev/null 2>&1 || {
  echo '[FAIL] systemctl introuvable. Le service GitHub Actions Linux requiert systemd.' >&2
  exit 22
}

if [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" != 'systemd' ]]; then
  echo '[FAIL] systemd ne fonctionne pas comme PID 1 dans cette distribution WSL.' >&2
  echo 'Active systemd dans /etc/wsl.conf puis redemarre WSL avant de relancer ce script.' >&2
  exit 23
fi

if (( EUID == 0 )); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo '[FAIL] sudo introuvable.' >&2
    exit 24
  }
  sudo -n true >/dev/null 2>&1 || {
    echo '[FAIL] sudo sans mot de passe est requis pour installer/demarrer le service runner.' >&2
    exit 25
  }
  SUDO=(sudo -n)
fi

runner_user="$(stat -c '%U' .runner 2>/dev/null || true)"
if [[ -z "$runner_user" || "$runner_user" == 'UNKNOWN' || "$runner_user" == 'root' ]]; then
  runner_user="${SUDO_USER:-${USER:-}}"
fi
[[ -n "$runner_user" && "$runner_user" != 'root' ]] || {
  echo '[FAIL] impossible de determiner un utilisateur non-root pour le service runner.' >&2
  exit 26
}
echo "RUNNER_SERVICE_USER=$runner_user"

status_output="$("${SUDO[@]}" ./svc.sh status 2>&1 || true)"
service_installed=0
if grep -Eq '/etc/systemd/system/actions\.runner\..+\.service|Loaded:[[:space:]]+loaded' <<<"$status_output"; then
  service_installed=1
fi

if listener_running; then
  if (( service_installed )) && grep -Eq 'Active:[[:space:]]+active[[:space:]]+\(running\)' <<<"$status_output"; then
    echo "$status_output"
    echo 'ANDROID_BUILD_RUNNER_SERVICE=ALREADY_RUNNING'
    exit 0
  fi

  echo '[FAIL] Runner.Listener fonctionne deja hors du service systemd.' >&2
  echo 'Arrete proprement ce lancement manuel avant d installer le service; aucun processus ne sera tue automatiquement.' >&2
  pgrep -af 'Runner\.Listener' >&2 || true
  exit 27
fi

if (( ! service_installed )); then
  echo '==> Install GitHub Actions runner systemd service'
  "${SUDO[@]}" ./svc.sh install "$runner_user"
  echo 'ANDROID_BUILD_RUNNER_SERVICE_INSTALL=PASS'
else
  echo 'ANDROID_BUILD_RUNNER_SERVICE_INSTALL=ALREADY_INSTALLED'
fi

if [[ "$CONFIGURE_NEEDRESTART" == '1' && -d /etc/needrestart ]]; then
  echo '==> Protect runner service from needrestart during package operations'
  # shellcheck disable=SC2016
  printf '%s\n' '$nrconf{override_rc}{qr(^actions\.runner\..+\.service$)} = 0;' \
    | "${SUDO[@]}" tee /etc/needrestart/conf.d/actions_runner_services.conf >/dev/null
  echo 'ANDROID_BUILD_RUNNER_NEEDRESTART=CONFIGURED'
else
  echo 'ANDROID_BUILD_RUNNER_NEEDRESTART=NOT_NEEDED'
fi

echo '==> Start GitHub Actions runner systemd service'
"${SUDO[@]}" ./svc.sh start

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if listener_running; then
    sleep 2
    if listener_running; then
      "${SUDO[@]}" ./svc.sh status || true
      echo 'ANDROID_BUILD_RUNNER_SERVICE=PASS'
      exit 0
    fi
  fi
  sleep 2
done

echo '[FAIL] service installe mais Runner.Listener ne reste pas actif.' >&2
"${SUDO[@]}" ./svc.sh status >&2 || true
exit 28
