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

install_ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    return
  fi
  [[ $EUID -eq 0 ]] || die "bootstrap installs packages: run it as root (sudo make bootstrap)"
  info "installing ansible-core from the distribution"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ansible-core
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core
  else
    die "unsupported package manager: install ansible-core (>= 2.16) yourself"
  fi
}

playbook() {
  local env
  env="$(resolve_env)"
  local args=(-i "inventories/${env}" "$@")
  [[ "${VAULT:-0}" == 1 ]] && args+=(--ask-vault-pass)
  [[ "${ASK_BECOME:-0}" == 1 ]] && args+=(--ask-become-pass)
  info "environment: ${env}"
  ansible-playbook "${args[@]}"
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
