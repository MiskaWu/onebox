# 0002. Pure Ansible on ansible-core built-in modules

- Status: Accepted
- Related: [0003](0003-make-is-the-operator-interface.md), [0014](0014-single-node-k3s.md), [0024](0024-render-mode-static-testing.md)

## Context

Everything onebox manages is configuration of one host: packages, systemd units, firewall
rules, files, containers and the manifests of one local Kubernetes cluster. There is no cloud
resource lifecycle to manage except DNS, which a single wildcard record covers
([0005](0005-certificates-dns01-and-tls-modes.md)). Hosts may have limited internet access, and
a fresh host must be deployable from distribution packages alone.

## Decision

- **Ansible only.** No Terraform, OpenTofu or Pulumi.
- **ansible-core built-ins only**, always with their fully qualified names. No Galaxy
  collections. What collections would provide is done with built-ins:
  - `authorized_key`, `mount`, `firewalld`, `seboolean` → `lineinfile`/`blockinfile`,
    templates, systemd units, and `command` with explicit `changed_when` (query first, then
    change);
  - Kubernetes objects → manifests rendered into k3s's auto-deploy directory; charts are
    installed by k3s's built-in helm-controller through `HelmChart` objects. No `helm`, no
    `kubectl` scripting, no Kubernetes collection on the host.
- **Zero-dependency bootstrap:** `deploy.sh bootstrap` installs `ansible-core` from the
  distribution and converges. Bash and the package manager are the only prerequisites.

## Consequences

- Stateless: every run reads reality. There is no state file that must be backed up, that can
  drift from the host, or that lives on the very forge the platform deploys.
- `--check --diff` stays meaningful for templates, files, packages and units.
- Accepted cost: `command`/`shell` tasks are skipped in check mode, so their idempotency is
  hand-written and invisible to dry runs. Read-only probes carry `check_mode: false` so check
  mode still sees the truth. [0024](0024-render-mode-static-testing.md) closes part of the gap.
- Accepted cost: some module conveniences are re-implemented (for example an append-only
  `authorized_keys`, which is safer here anyway — see [0009](0009-guarded-irreversible-changes.md)).
- Accepted cost: installing or upgrading a chart needs the chart repository to be reachable at
  that moment; charts already installed are unaffected by an outage.

## Alternatives considered

- **Pulumi or Terraform driving shell commands.** Every idempotent module would be rewritten as
  create/update/delete scripts; previews of command resources only say "will run this"; and a
  state backend appears. Hosted on the platform's own forge it is a bootstrap loop; stored on
  the managed host it dies with the host.
- **Galaxy collections.** More convenient modules, but versioned dependencies to fetch on
  hosts that may be offline, and the bootstrap stops being "distribution package plus this
  repository".
- **helm/kubectl binaries or the Kubernetes collection.** Extra moving parts duplicating the
  helm-controller k3s already runs.

## Revisit when

Resources that need CRUD against external APIs grow past roughly a dozen across several
providers (many DNS record types, cloud KMS, object storage buckets, cloud networks). At that
point a declarative cloud tool earns its state backend — for that layer only. Managing a couple
of non-A records (mail SPF/DKIM) is not enough on its own.
