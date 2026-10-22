#!/usr/bin/env bash
# Install the pinned static-check toolchain into .tools/ (nothing global, no root).
#   .tools/venv   ansible-core, ansible-lint, yamllint  (tests/requirements.txt)
#   .tools/bin    kubeconform, shellcheck               (release archives, sha256-verified)
# podman (Quadlet dry-run, `caddy validate` in a container) comes from the system.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${REPO_ROOT}/.tools"
mkdir -p "${TOOLS}/bin" "${TOOLS}/cache"

KUBECONFORM_VERSION=v0.8.0
SHELLCHECK_VERSION=v0.11.0

case "$(uname -m)" in
  x86_64)
    KUBECONFORM_ASSET=kubeconform-linux-amd64.tar.gz
    KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
    SHELLCHECK_ASSET=shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz
    SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  *)
    echo "tools.sh: only x86_64 archives are pinned; install kubeconform and shellcheck yourself" >&2
    exit 1
    ;;
esac

fetch() { # url sha256 dest
  local url="$1" sum="$2" dest="$3"
  if [[ ! -f "$dest" ]] || ! echo "${sum}  ${dest}" | sha256sum -c --quiet - 2>/dev/null; then
    curl -fsSL --retry 3 -o "${dest}.part" "$url"
    echo "${sum}  ${dest}.part" | sha256sum -c --quiet -
    mv "${dest}.part" "$dest"
  fi
}

# ── Python tools ──
if [[ ! -x "${TOOLS}/venv/bin/ansible-lint" ]] || ! cmp -s "${REPO_ROOT}/tests/requirements.txt" "${TOOLS}/venv/.requirements"; then
  if command -v uv >/dev/null 2>&1; then
    uv venv -q --allow-existing "${TOOLS}/venv"
    VIRTUAL_ENV="${TOOLS}/venv" uv pip install -q -r "${REPO_ROOT}/tests/requirements.txt"
  else
    python3 -m venv "${TOOLS}/venv"
    "${TOOLS}/venv/bin/pip" install -q -r "${REPO_ROOT}/tests/requirements.txt"
  fi
  cp "${REPO_ROOT}/tests/requirements.txt" "${TOOLS}/venv/.requirements"
fi

# ── kubeconform ──
fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/${KUBECONFORM_ASSET}" \
  "$KUBECONFORM_SHA256" "${TOOLS}/cache/${KUBECONFORM_ASSET}"
tar -xzf "${TOOLS}/cache/${KUBECONFORM_ASSET}" -C "${TOOLS}/bin" kubeconform

# ── shellcheck ──
fetch "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${SHELLCHECK_ASSET}" \
  "$SHELLCHECK_SHA256" "${TOOLS}/cache/${SHELLCHECK_ASSET}"
tar -xJf "${TOOLS}/cache/${SHELLCHECK_ASSET}" -C "${TOOLS}/cache"
install -m 755 "${TOOLS}/cache/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "${TOOLS}/bin/shellcheck"

echo "tools ready in ${TOOLS}"
