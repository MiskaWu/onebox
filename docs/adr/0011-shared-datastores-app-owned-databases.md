# 0011. Shared datastores with app-owned databases; a dedicated database is the escape hatch

- Status: Accepted
- Related: [0009](0009-guarded-irreversible-changes.md), [0010](0010-podman-quadlet-services.md), [0012](0012-datastore-reachability.md), [0017](0017-openbao-and-external-secrets.md)

## Context

The identity provider, the secrets store's consumers and most applications need PostgreSQL;
applications also want a cache, a message bus and a key-value store. If every service bundles
its own database, the host runs many copies with separate upgrades, backups and monitoring.

## Decision

- **`datastores` runs shared engines** — PostgreSQL (the default), MySQL, Redis, NATS, etcd — as
  Quadlet containers on the private podman network `onebox_data_network` with a fixed subnet.
  Podman clients join the network and use container names (`postgres:5432`). Host tools use the
  `127.0.0.1` ports.
- **`datastores` owns only superusers.** A service that needs a database creates its own role
  and database in its own role, idempotently, with the application role as owner (no per-object
  grants). Creating databases dynamically is an opt-in privilege.
- **MySQL is an escape hatch,** not an alternative default: only for software whose upstream
  supports nothing else.
- **Isolation escape hatch:** an application that must be isolated runs a dedicated database
  container on its own private network, publishing nothing. Switching between shared and
  dedicated does not migrate data.
- **Every datastore requires authentication.** Pods can route to the data network
  ([0012](0012-datastore-reachability.md)), so "private network, no password" no longer holds.
  Passwords reach engines through configuration files, stdin or podman secrets — never command
  lines or world-readable units.
- **Redis is a three-master cluster without replicas** on one host. It buys no availability
  (one host); it buys protocol parity: applications use cluster-aware clients, hash tags and
  database 0 from day one, so moving to a real or managed cluster changes nothing in the app.
  Cluster gossip carries IP addresses, so nodes get fixed IPs and the network a fixed subnet.
  The cluster bus itself is unauthenticated (Redis warns about it) and pods can reach the data
  network, so the bus runs over TLS with a role-generated CA and protected mode on.
  Cluster creation is guarded by `cluster_known_nodes > 1`, not `cluster_state:ok`: a degraded
  cluster reports `fail`, and re-running creation would hit "node is not empty".
- **Resets follow the protect-list pattern** ([0009](0009-guarded-irreversible-changes.md)): all
  application data in all engines goes together (a cache or registry pointing at deleted rows is
  worse than everything dirty); platform-owned databases (identity provider) and system
  databases survive. Engine details that matter: `DROP DATABASE … WITH (FORCE)` because crashing
  apps keep reconnecting; `FLUSHALL` on every Redis master because each holds only its slots;
  argv-form commands for distroless images without a shell.
- **Host-wide datastore credentials** (one Redis password, one NATS user, one etcd root) are
  platform secrets, not copied per tenant.

## Consequences

- One backup, upgrade and monitoring target per engine; a new database is one declaration.
- Accepted cost: shared fate and shared maintenance windows; one tenant's load or connection
  count affects the others.
- Accepted cost: with host-wide credentials, once two tenants use the same Redis or NATS, each
  can read the other's data. Real separation needs per-tenant ACL users or accounts on the
  engine.
- Accepted cost: Redis cluster restrictions (no multi-key operations across slots without hash
  tags, no `SELECT`) bind application code.

## Alternatives considered

- **A database per service:** more containers, backups and upgrade paths for no benefit at this
  scale.
- **Managed databases:** not available on-premises or offline.
- **Standalone Redis:** simpler, but no parity; switching later requires a data wipe because the
  formats differ.
- **Delete lists for resets:** anything new and unlisted survives as invisible stale state.

## Revisit when

- A tenant needs isolation: use the dedicated-database pattern, do not abandon sharing.
- A second host exists: replicas and real failover become meaningful.
- Tenants need different reset cycles: scope resets per application.
- A second tenant starts using Redis or NATS: introduce per-tenant ACLs first.
