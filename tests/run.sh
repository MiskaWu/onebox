#!/usr/bin/env bash
# Static checks for onebox — no target host needed.
#
#   tests/run.sh lint      shellcheck, yamllint, ansible-lint
#   tests/run.sh syntax    ansible-playbook --syntax-check for every playbook
#   tests/run.sh render    render every role's files for each scenario into .render/<scenario>/
#   tests/run.sh validate  check the rendered files: Quadlet dry-run, caddy validate, kubeconform
#   tests/run.sh all       everything above, in that order
#   tests/run.sh render validate   several stages in one call
#
# Environment:
#   SCENARIOS="a b"   only these scenarios (default: every directory in tests/scenarios/)
#   RENDER_ROOT=dir   where rendered files go (default: .render/)
#
# Scenarios live in tests/scenarios/<name>/ (an inventory each). They exist to push every
# provider branch (OS family, TLS mode, DNS provider, optional components) through the
# templates, so a broken branch fails here instead of on a real host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TOOLS="${REPO_ROOT}/.tools"
[[ -x "${TOOLS}/venv/bin/ansible-lint" && -x "${TOOLS}/bin/kubeconform" ]] || tests/tools.sh
export PATH="${TOOLS}/venv/bin:${TOOLS}/bin:${PATH}"
export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"

CADDY_IMAGE="docker.io/library/caddy:2.11.7"
QUADLET_GENERATOR="${QUADLET_GENERATOR:-/usr/lib/systemd/system-generators/podman-system-generator}"
RENDER_ROOT="${RENDER_ROOT:-${REPO_ROOT}/.render}"

failures=0
step() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }

scenarios() {
  if [[ -n "${SCENARIOS:-}" ]]; then
    tr ' ' '\n' <<<"$SCENARIOS" | grep -v '^$'
    return
  fi
  local d
  for d in tests/scenarios/*/; do
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}

shell_files() {
  {
    printf '%s\n' deploy.sh
    find tests scripts roles -type f -name '*.sh' -not -path '*/.render/*'
    # extensionless scripts that start with a bash shebang (e.g. roles/*/files/*)
    find roles -type f -path '*/files/*' ! -name '*.*' -exec grep -l '^#!/usr/bin/env bash' {} +
  } | sort -u
}

do_lint() {
  step "shellcheck"
  local f
  while IFS= read -r f; do
    if shellcheck -x "$f"; then ok "$f"; else bad "$f"; fi
  done < <(shell_files)

  step "yamllint"
  if yamllint -s .; then ok "yamllint"; else bad "yamllint"; fi

  step "ansible-lint"
  if ansible-lint -q site.yml playbooks/ roles/ tests/render.yml; then ok "ansible-lint"; else bad "ansible-lint"; fi
}

do_syntax() {
  step "syntax-check"
  local pb
  for pb in site.yml playbooks/*.yml; do
    [[ -e "$pb" ]] || continue
    if ansible-playbook --syntax-check -i inventories/example "$pb" >/dev/null; then ok "$pb"; else bad "$pb"; fi
  done
}

do_render() {
  local s out
  for s in $(scenarios); do
    step "render: ${s}"
    out="${RENDER_ROOT}/${s}"
    rm -rf "$out"
    mkdir -p "$out"
    if ansible-playbook -i "tests/scenarios/${s}" tests/render.yml \
        -e "onebox_root=${out}" >"${out}.log" 2>&1; then
      ok "$(find "$out" -type f | wc -l) files → ${out}"
    else
      bad "render failed, see ${out}.log"
      tail -n 30 "${out}.log" | sed 's/^/      /'
    fi
  done
}

validate_quadlet() { # render dir
  local dir="$1/etc/containers/systemd" out
  [[ -d "$dir" ]] || return 0
  if [[ ! -x "$QUADLET_GENERATOR" ]]; then
    echo "  skip  Quadlet: ${QUADLET_GENERATOR} not found (install podman >= 4.9)"
    return 0
  fi
  if out="$(QUADLET_UNIT_DIRS="$dir" "$QUADLET_GENERATOR" --dryrun 2>&1)" && ! grep -qiE 'error|unsupported key|converting .* failed' <<<"$out"; then
    ok "Quadlet: $(grep -c '^---' <<<"$out") units generate cleanly"
  else
    bad "Quadlet dry-run"
    grep -iE 'error|unsupported|failed|warning' <<<"$out" | head -n 20 | sed 's/^/      /'
  fi
}

# The rendered Dockerfile is built (cached by its hash) so the validation runs the exact
# binary a host would get — including DNS provider plugins — and the Dockerfile itself is
# tested on the way.
caddy_test_image() { # render dir → image name on stdout
  local dockerfile="$1/var/lib/onebox/build/caddy/Dockerfile" tag
  if [[ ! -f "$dockerfile" ]]; then
    printf '%s\n' "$CADDY_IMAGE"
    return
  fi
  tag="localhost/onebox-caddy-test:$(sha256sum "$dockerfile" | cut -c1-12)"
  if ! podman image exists "$tag"; then
    echo "  ...   building $tag (first time takes a few minutes)" >&2
    podman build -q -t "$tag" -f "$dockerfile" "$(dirname "$dockerfile")" >/dev/null || return 1
  fi
  printf '%s\n' "$tag"
}

validate_caddy() { # render dir
  local dir="$1/etc/caddy"
  [[ -f "$dir/Caddyfile" ]] || return 0
  if ! command -v podman >/dev/null 2>&1; then
    echo "  skip  caddy validate: podman not installed"
    return 0
  fi
  # files mode references a certificate on disk: give validation a throwaway one
  if grep -qE '^\s*tls /etc/caddy/certs/' "$dir/Caddyfile" && [[ ! -f "$dir/certs/fullchain.pem" ]]; then
    mkdir -p "$dir/certs"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=onebox-test" \
      -keyout "$dir/certs/privkey.pem" -out "$dir/certs/fullchain.pem" >/dev/null 2>&1
  fi
  local image out
  if ! image="$(caddy_test_image "$1")"; then
    bad "caddy image build"
    return
  fi
  if out="$(podman run --rm --network none -v "$dir:/etc/caddy:ro,Z" "$image" \
      caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile --envfile /etc/caddy/caddy.env 2>&1)"; then
    ok "caddy validate (${image##*/})"
  else
    bad "caddy validate (${image##*/})"
    grep -E '"level":"error"|Error' <<<"$out" | tail -n 8 | sed 's/^/      /'
  fi
}

validate_k8s() { # render dir
  local files=()
  mapfile -t files < <(find "$1" -type f -path '*/manifests/*' \( -name '*.yaml' -o -name '*.yml' \) | sort)
  [[ ${#files[@]} -gt 0 ]] || return 0
  if kubeconform -strict -summary -kubernetes-version 1.33.0 \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "${files[@]}"; then
    ok "kubeconform (${#files[@]} files)"
  else
    bad "kubeconform"
  fi
}

do_validate() {
  local s
  for s in $(scenarios); do
    [[ -d "${RENDER_ROOT}/${s}" ]] || { bad "${s}: not rendered (run tests/run.sh render)"; continue; }
    step "validate: ${s}"
    validate_quadlet "${RENDER_ROOT}/${s}"
    validate_caddy "${RENDER_ROOT}/${s}"
    validate_k8s "${RENDER_ROOT}/${s}"
  done
}

[[ $# -gt 0 ]] || set -- all
for stage in "$@"; do
  case "$stage" in
    lint) do_lint ;;
    syntax) do_syntax ;;
    render) do_render ;;
    validate) do_validate ;;
    all) do_lint; do_syntax; do_render; do_validate ;;
    *) echo "usage: tests/run.sh [lint|syntax|render|validate|all]..." >&2; exit 2 ;;
  esac
done

echo
if [[ $failures -gt 0 ]]; then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi
printf '\033[32mall checks passed\033[0m\n'
