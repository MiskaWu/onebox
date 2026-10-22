# 0024. Render mode: test every provider branch statically, with the host's own validators

- Status: Accepted
- Related: [0002](0002-ansible-core-only.md), [0004](0004-host-native-edge-proxy.md), [0014](0014-single-node-k3s.md), [0022](0022-reported-success-did-nothing.md)

## Context

Most defects in an infrastructure repository are configuration defects that only show on a real
host: a Caddyfile that does not parse with the plugins actually compiled in, a Quadlet key the
generator rejects, a manifest the API server refuses. `--check` skips every `command` task and
understands none of these formats. Booting a VM for every combination of OS family × TLS mode ×
DNS provider × components is too slow to run on every commit — so most branches would never run
until someone needed them.

## Decision

- **Every role separates file writing into `tasks/render.yml`.** Every destination is prefixed
  with `{{ onebox_root }}`; ownership uses `onebox_owner`/`onebox_group` (or a role variable)
  that becomes `omit` in render mode; parent directories that normally pre-exist are created
  only in render mode; every handler is guarded with `when: not onebox_render_only`. `main.yml`
  includes `render.yml`, so the same tasks write the real host.
- **Templates never read `ansible_facts`** (facts are not gathered when rendering); OS-specific
  values come from `onebox_os_family` and `vars/<family>.yml`.
- **`tests/render.yml`** runs the baseline and each enabled component's `render.yml` against a
  scenario inventory into a scratch directory, and refuses an empty root or `/`.
- **Scenarios** (`tests/scenarios/<name>/`) exist to push each provider branch through the
  templates: OS family, firewall backend, TLS mode, DNS provider, admin API mode, edge-owned
  sites, components on and off.
- **Validators run the tools the host would run** on the rendered tree:
  - podman's Quadlet generator in dry-run mode on the rendered units;
  - `caddy validate` executed with the exact binary built from the rendered Dockerfile — DNS
    plugins included, cached by the Dockerfile's hash, with a throwaway certificate for `files`
    mode — so the Dockerfile is tested on the way;
  - `kubeconform -strict` with CRD schemas on rendered manifests;
  - plus shellcheck, yamllint, ansible-lint (production profile) and `--syntax-check`.
- **The check toolchain is pinned** and installed into `.tools/` (checksum-verified archives,
  pinned Python requirements); nothing is installed globally.
- **`make test` is green before every commit.**

## Consequences

- Every provider branch is exercised in seconds to minutes, without a host.
- Accepted cost: discipline. A file written outside `render.yml` escapes the tests.
- Accepted cost: behaviour that depends on runtime state (command output, facts, service
  responses) is not covered; first deployments are still verified live
  ([0022](0022-reported-success-did-nothing.md)). Render mode also does not enforce component
  dependencies; preflight does at runtime.
- Accepted cost: validation needs podman and network access for the first Caddy build and for
  the CRD schema catalogue.

## Alternatives considered

- **Molecule with containers or VMs:** systemd, firewalld and podman inside containers are
  awkward, and VMs are slow; a good *later* integration layer, not a per-commit gate.
- **`--check` only:** skips command tasks and cannot validate configuration semantics.
- **Template unit tests with assertions on strings:** prove the text, not that the real parser
  accepts it.

## Revisit when

- The roles stabilise: add a VM-based integration run per OS family on a schedule.
- CI must run air-gapped: mirror the CRD schema catalogue and the builder images.
