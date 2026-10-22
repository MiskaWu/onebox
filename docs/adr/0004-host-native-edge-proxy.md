# 0004. A host-native edge proxy, built reproducibly in a container

- Status: Accepted
- Related: [0005](0005-certificates-dns01-and-tls-modes.md), [0006](0006-internal-only-by-default.md), [0015](0015-loopback-cluster-gateway.md), [0019](0019-ci-runner-on-the-host.md)

## Context

Every HTTP service and the Kubernetes cluster need HTTPS under one domain. The front door must
keep working when podman, containerd or k3s misbehave, because it fronts all of them.
Distribution packages of Caddy carry no DNS provider plugins (needed for DNS-01); downloading a
custom build from a build service is neither reproducible nor durable.

## Decision

- **Caddy is the only process on 80/443.** It runs under host systemd as an unprivileged
  `caddy` user with `CAP_NET_BIND_SERVICE` — not in a container and not in the cluster, for the
  same reason sshd is not containerised: its life must not depend on a workload runtime.
- **Reproducible binary.** A rendered Dockerfile compiles Caddy with xcaddy in the official
  builder image (pinned Caddy version, plugins from the DNS provider catalog plus
  `edge_extra_modules`) and fails the build if the DNS module is missing. The binary is copied
  out to the host; the image is never run.
- **One contract.** The main Caddyfile owns global TLS policy and two snippets —
  `onebox_site` (TLS/logging/HSTS for every site) and `onebox_internal_only` (the LAN guard,
  [0006](0006-internal-only-by-default.md)) — and imports `conf.d/*.caddy`. Each service ships
  exactly one drop-in through `caddy_vhost`: `import onebox_site`, `reverse_proxy
  127.0.0.1:<port>`, no `tls` directive. Nothing else edits the main Caddyfile. `edge_sites` is
  only for sites that belong to no service (portal, static files, redirects).
- **The portal is derived, never listed.** `caddy_vhost` writes one card file per drop-in and
  rebuilds the portal page from all cards. There is no second list of services to keep in sync.
  The page is a static file, so updating it needs no reload.
- **Admin API on a 0700 unix socket** (`edge_admin_mode: unix`), or off. Caddy's admin API has
  no authentication; on its default `localhost:2019` any local process — including CI jobs
  ([0019](0019-ci-runner-on-the-host.md)) — can read and replace the entire edge configuration.
  Origin checks do not stop local requests. `caddy reload` itself talks to the admin API, so the
  unit's `ExecReload` passes the socket address explicitly; with the API off, every config
  change becomes a restart.
- **Handler order:** restart before reload. A new binary or environment only takes effect on a
  fresh exec, and a reload pushed to the old process fails when the new config needs a module
  only the new binary has.
- **Long-lived connections:** per-vhost `stream_close_delay` (a reload otherwise closes every
  WebSocket immediately) and `lb_try_duration` (retry while an upstream restarts instead of
  answering 502, e.g. the cluster gateway's recreate, [0015](0015-loopback-cluster-gateway.md)).

## Consequences

- The edge survives podman and cluster outages and keeps serving everything else.
- The exact production binary is rebuilt in tests and used to `caddy validate` every rendered
  configuration ([0024](0024-render-mode-static-testing.md)).
- Accepted cost: building needs podman and network access to fetch Go modules; the first build
  takes minutes.
- Accepted cost: reloads still end long-lived streams after the delay; clients must reconnect.
- `/var/lib/caddy` holds ACME accounts and certificates. Losing it means re-issuing everything
  and possibly hitting CA rate limits — it belongs in backups.

## Alternatives considered

- **Caddy in a container:** the front door would share fate with the podman service.
- **Distribution package:** no DNS provider plugins.
- **Downloading a custom binary from a build service:** not reproducible; the URL rots.
- **The cluster's ingress as the edge:** the edge would die with the cluster, and podman
  services would have to route through Kubernetes.
- **Hardening the TCP admin endpoint with origin checks:** not authentication.

## Revisit when

- The edge must be highly available (several hosts): shared certificate storage and a load
  balancer in front.
- Caddy's admin API gains authentication.
- `caddy_edge` is reused without `caddy_vhost` (another host, another repository): the
  cross-role contract variables must still come from one place, not be copied into role
  defaults.
