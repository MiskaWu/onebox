# 0001. One host per environment, one repository, roles as the unit of decoupling

- Status: Accepted
- Related: [0002](0002-ansible-core-only.md), [0016](0016-gitops-central-repository.md), [0018](0018-one-oidc-issuer.md)

## Context

A small team needs a Git forge, CI, single sign-on, a secrets store, shared databases and a
Kubernetes cluster. These pieces are coupled through a handful of contracts (edge drop-ins,
the private data network, OIDC clients, the OpenBao ↔ External Secrets names). A change to a
contract touches several services at once. The same platform has to be reusable in very
different environments, and environments (dev, test, prod) must not leak into each other.

## Decision

- **One host runs one environment.** The environment boundary is a separate *instance*:
  its own host, datastores, identity provider, signing keys and issuer. Not namespaces, not
  organisations inside one identity provider, not hostname prefixes on a shared host. A
  consequence: identity names carry no `-dev` suffix — the same person has the same identity
  string in every environment, and the instance is what differs.
- **One repository for the whole platform.** Services are decoupled through roles with small,
  explicit contracts, not through separate Git repositories. A contract change is one atomic
  commit.
- **Application workloads live elsewhere.** Their code and manifests sit in their own
  repositories and reach the cluster through GitOps ([0016](0016-gitops-central-repository.md)).
  The platform repository never contains workload manifests.
- **Every value is declared exactly once:**
  - environment facts (domain, IPs, CIDRs, people, accounts) only in `inventories/<env>/`;
  - values read by more than one role in `group_vars/all/onebox.yml`;
  - role-only knobs in that role's `defaults/main.yml`, prefixed with the role name.
- **Everything optional is a component.** `onebox_components` selects what runs;
  `onebox_component_requires` declares dependencies and `roles/preflight` enforces them. A role
  that is not listed does not touch the host.

## Consequences

- Contract changes are atomic and reviewable in one place; one checkout explains the platform.
- Environments are isolated by construction: a production account cannot sign in to a dev
  service because the identity providers are different instances.
- Accepted cost: the host is a single failure domain. No high availability; losing the host
  loses everything that has no off-host copy ([0025](0025-off-host-copies.md)).
- Duplicate declarations become a defect class to guard against:
  - a value redeclared in role defaults is silently overridden by `group_vars`, so editing the
    role default "upgrades" nothing and reports no error;
  - play-level `vars:` outrank inventory `group_vars`, so a maintenance playbook that hardcodes
    paths can report success while deleting stale paths and leaving the real ones in place.
  Shared values are therefore never redeclared, and roles assert their presence up front
  instead of carrying a fallback copy.
- Ansible loads `group_vars` only next to the inventory and next to the playbook. Playbooks in
  `playbooks/` reach the repository-root `group_vars` through a symlink
  (`playbooks/group_vars → ../group_vars`); without it they fail with undefined variables, and
  rarely used maintenance playbooks can stay broken unnoticed for months.

## Alternatives considered

- **Repository per service.** Turns every contract change into multi-repository coordination
  with no atomicity, for a deployment that is one host anyway.
- **Several environments on one host** (namespaces, virtual clusters, one identity provider
  with an application per environment). With one identity provider, any user of an
  organisation can sign in to every application of that organisation; separating them takes
  after-the-fact tags or permissions. Real isolation needs separate instances anyway.
- **Multi-host from day one.** Buys availability that a small team rarely needs, paid for with
  quorum, replication and failover operations every day.

## Revisit when

- An environment must span several hosts (availability, capacity): the inventory grows groups;
  the contracts stay.
- A platform piece needs a machine of its own (a VPN control plane, a build farm): decide
  first whether it becomes another inventory host here or a separate repository.
