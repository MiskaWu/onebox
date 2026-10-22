# 0010. Platform services are rootful podman containers managed by Quadlet

- Status: Accepted
- Related: [0004](0004-host-native-edge-proxy.md), [0007](0007-host-firewall-scope.md), [0019](0019-ci-runner-on-the-host.md), [0021](0021-secrets-handling.md), [0023](0023-version-pinning.md)

## Context

Platform services ship as OCI images. They need systemd supervision, boot ordering, logs in
the journal and predictable restarts — without depending on the Kubernetes cluster that the
platform itself provides.

## Decision

- **Rootful podman with Quadlet units** in `/etc/containers/systemd/`; each container becomes a
  systemd service. The generic primitive is `roles/podman_quadlet` (name, image, publish, env,
  secrets, volumes, networks, extra lines); a service with unusual needs (for example a
  monolithic forge image with shared-memory size, two ports and nested volumes) ships its own
  unit template.
- **Publish on `127.0.0.1` only** ([0007](0007-host-firewall-scope.md)).
- **Secrets as podman secrets** (`Secret=…,type=env`), never `Environment=`: unit files are
  world-readable and `--check --diff` prints rendered templates. A file of SHA-256 fingerprints
  decides when a secret must be recreated and the container restarted; values are never written
  anywhere else.
- **No restart without a reason:** converging an unchanged host never bounces a container; only
  a changed unit or secret restarts it.
- **Pinned images, auto-update off by default.** The trade-off is determinism versus unattended
  patching, not right versus wrong: stateful containers restarted unattended are a bigger risk
  than the patch gain; podman's auto-update rollback keys on sd_notify, not health checks, so
  it misses "starts, then fails"; and a host without public inbound has little marginal exposure
  to image CVEs. Version bumps are deliberate ([0023](0023-version-pinning.md)).
- **Two deliberate exceptions** run natively: the edge proxy ([0004](0004-host-native-edge-proxy.md))
  and the CI runner ([0019](0019-ci-runner-on-the-host.md)).
- **State lives in volumes or host paths,** never in the container layer; SELinux relabelling
  with `:Z` (a no-op where SELinux is off).

## Consequences

- One model for every service; `systemctl` and `journalctl` work as everywhere else.
- Accepted cost: rootful containers without user-namespace mapping run as host UIDs. A container
  process running as UID 1000 appears under whichever person owns UID 1000 on the host — never
  `pkill -u` a user during offboarding ([0013](0013-personal-operator-accounts.md)).
- Accepted cost: nobody patches images automatically; someone owns the bump cadence.

## Alternatives considered

- **Docker/compose:** an extra daemon and a second supervision model beside systemd.
- **Platform services in k3s:** the platform would depend on the cluster it provides, and a
  cluster rebuild would take the forge, identity provider and secrets store with it.
- **Rootless services:** port and volume friction for no gain on a single-purpose host; rootless
  is reserved for CI builds.

## Revisit when

- The host gains public inbound traffic: patch latency matters more; reconsider auto-update with
  health-checked rollback.
- Podman changes Quadlet semantics in a way the primitive cannot absorb.
