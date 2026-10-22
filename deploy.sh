#!/usr/bin/env bash
# onebox deploy entry point. Depends on nothing but bash and the distro package manager:
# `bootstrap` installs ansible-core itself, so a fresh host needs only this repo.
#
# Humans use `make <target>`; make calls this script; this script calls ansible-playbook.
#
#   ./deploy.sh bootstrap                 install ansible-core, then converge everything
#   ./deploy.sh apply [--tags a,b]        converge (all components, or just the tagged ones)
#   ./deploy.sh check [--tags a,b]        dry run with diff
#   ./deploy.sh status                    show unit / pod state of the enabled components
#   ./deploy.sh op <role> <task> [-e …]   run roles/<role>/tasks/<task>.yml (an operation)
#   ./deploy.sh run <playbook> [-e …]     run playbooks/<playbook>.yml
#   ./deploy.sh envs                      list environments under inventories/
#   ./deploy.sh env                       print the environment that would be used
#
# Environment variables:
#   ONEBOX_ENV   inventory directory under inventories/ (auto-picked when there is only one
#                besides `example`)
#   VAULT=1      secrets.yml is ansible-vault encrypted: prompt for the vault password
#                (ANSIBLE_VAULT_PASSWORD_FILE works too and needs no prompt)
#   ASK_BECOME=1 prompt for the sudo password when not running as root
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

die() { printf 'deploy.sh: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*" >&2; }

list_envs() {
  local d
  for d in inventories/*/; do
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}

resolve_env() {
  if [[ -n "${ONEBOX_ENV:-}" ]]; then
    [[ -d "inventories/${ONEBOX_ENV}" ]] || die "inventories/${ONEBOX_ENV} does not exist (make init ENV=${ONEBOX_ENV})"
    printf '%s\n' "$ONEBOX_ENV"
    return
  fi
  local envs=()
  mapfile -t envs < <(list_envs | grep -vx example || true)
  case "${#envs[@]}" in
    1) printf '%s\n' "${envs[0]}" ;;
    0) die "no environment yet: make init ENV=<name> (copies inventories/example)" ;;
    *) die "several environments (${envs[*]}): set ENV=<name>" ;;
  esac
}

# ansible-core: the distribution's package when it is new enough, otherwise a pinned copy in a
# venv. EL9's AppStream ships 2.14, below the 2.16 the roles need; the venv uses the same
# version as the test toolchain (tests/requirements.txt).
ANSIBLE_CORE_MIN=2.16
ANSIBLE_CORE_PIN=2.21.5
ANSIBLE_VENV=/opt/onebox/ansible

version_ge() { # a b → a >= b
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

ansible_version_of() { # ansible-playbook binary → x.y.z
  "$1" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

ansible_playbook_bin() {
  local bin
  for bin in "${ANSIBLE_VENV}/bin/ansible-playbook" "$(command -v ansible-playbook 2>/dev/null || true)"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    if version_ge "$(ansible_version_of "$bin")" "$ANSIBLE_CORE_MIN"; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  return 1
}

install_ansible_venv() {
  local py=python3
  if command -v dnf >/dev/null 2>&1; then
    # ansible-core >= 2.20 needs Python >= 3.12 on the controller; EL9 has it as python3.12.
    dnf install -y python3.12 python3.12-pip
    py=python3.12
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip
  fi
  info "installing ansible-core ${ANSIBLE_CORE_PIN} into ${ANSIBLE_VENV}"
  "$py" -m venv "$ANSIBLE_VENV"
  "${ANSIBLE_VENV}/bin/pip" install --quiet "ansible-core==${ANSIBLE_CORE_PIN}"
}

install_ansible() {
  ansible_playbook_bin >/dev/null && return
  [[ $EUID -eq 0 ]] || die "bootstrap installs packages: run it as root (sudo make bootstrap)"
  info "installing ansible-core from the distribution"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ansible-core || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core || true
  else
    die "unsupported package manager: install ansible-core (>= ${ANSIBLE_CORE_MIN}) yourself"
  fi
  if ! ansible_playbook_bin >/dev/null; then
    info "the distribution's ansible-core is older than ${ANSIBLE_CORE_MIN}"
    install_ansible_venv
  fi
  ansible_playbook_bin >/dev/null || die "could not install ansible-core >= ${ANSIBLE_CORE_MIN}"
}

playbook() {
  local env
  env="$(resolve_env)"
  local args=(-i "inventories/${env}" "$@")
  [[ "${VAULT:-0}" == 1 ]] && args+=(--ask-vault-pass)
  [[ "${ASK_BECOME:-0}" == 1 ]] && args+=(--ask-become-pass)
  local bin
  bin="$(ansible_playbook_bin)" || die "ansible-core >= ${ANSIBLE_CORE_MIN} not found: run sudo make bootstrap"
  info "environment: ${env}"
  "$bin" "${args[@]}"
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage 1
shift

case "$cmd" in
  bootstrap)
    install_ansible
    playbook site.yml "$@"
    ;;
  apply)
    playbook site.yml "$@"
    ;;
  check)
    playbook site.yml --check --diff "$@"
    ;;
  status)
    playbook playbooks/status.yml "$@"
    ;;
  op)
    [[ $# -ge 2 ]] || die "usage: ./deploy.sh op <role> <task> [ansible-playbook args]"
    role="$1" task="$2"
    shift 2
    [[ -f "roles/${role}/tasks/${task}.yml" ]] || die "no operation roles/${role}/tasks/${task}.yml"
    playbook playbooks/op.yml -e "onebox_op_role=${role}" -e "onebox_op_task=${task}" "$@"
    ;;
  run)
    [[ $# -ge 1 ]] || die "usage: ./deploy.sh run <playbook> [ansible-playbook args]"
    name="$1"
    shift
    [[ -f "playbooks/${name}.yml" ]] || die "no playbook playbooks/${name}.yml"
    playbook "playbooks/${name}.yml" "$@"
    ;;
  envs)
    list_envs
    ;;
  env)
    resolve_env
    ;;
  -h|--help|help)
    usage 0
    ;;
  *)
    die "unknown command: ${cmd} (see ./deploy.sh help)"
    ;;
esac
