# 0015. The cluster gateway is our own Traefik on loopback, serving Ingress and Gateway API

- Status: Accepted
- Related: [0004](0004-host-native-edge-proxy.md), [0005](0005-certificates-dns01-and-tls-modes.md), [0006](0006-internal-only-by-default.md), [0007](0007-host-firewall-scope.md), [0014](0014-single-node-k3s.md)

## Context

The edge must never know about pods, yet the cluster needs host- and path-based routing. The
`Ingress` API is frozen upstream, the community ingress-nginx controller has been retired, and
Gateway API is the direction of travel; weighted canaries need a router that can split traffic.
Some workloads are not HTTP at all.

## Decision

- **Two layers.** The edge terminates TLS and routes cluster hostnames to
  `127.0.0.1:<k3s_gateway_http_port>` (31080 by default). The gateway routes inside the cluster by
  the `Host` header (Caddy preserves it for plain-HTTP upstreams). HTTP workloads never
  terminate TLS themselves.
- **Our own Traefik,** installed and pinned through a `HelmChart` object, with
  `hostNetwork: true` and every entrypoint bound explicitly to `127.0.0.1` (or to a named
  address for opt-in TCP entrypoints). **No Service at all:** a Service is a possible NodePort or
  load balancer — a path into the cluster that bypasses the edge. A preflight keeps `traefik` in
  k3s's disable list, and the manifest file name avoids "traefik" so it never collides with
  k3s's own addon handling.
- **`updateStrategy: Recreate`** (one node cannot run two pods on the same host ports), with
  `rollingUpdate` explicitly null — Helm's deep merge keeps the chart default and the API rejects
  the combination — and `dnsPolicy: ClusterFirstWithHostNet`. The edge bridges the restart gap
  with `lb_try_duration`.
- **Both routing APIs.** `Ingress` stays for charts that only ship Ingress templates (Argo CD);
  Gateway API Standard-channel CRDs are installed by the platform, pinned by version and
  checksum and applied before the gateway. **New workloads use `HTTPRoute`** (portable, weighted
  backends).
- **Argo Rollouts** is the release engine. Blue/green is a Service selector switch and works with
  any router; canary weights go through the Gateway API plugin, pinned by version and checksum.
  The plugin is pre-1.0, so only canaries depend on it. Automatic promotion is off.
- **Workload hostnames:** a catch-all `*.apps.<domain>` points at the gateway, so new and
  short-lived environments need no platform change. Caddy matches the most specific site first,
  so flat platform names are never captured ([0006](0006-internal-only-by-default.md)).
- **Non-HTTP traffic is opt-in and off by default,** in this order of preference:
  1. **WebSocket through the edge** — browsers cannot open raw TCP anyway; zero new ports.
  2. **TLS with SNI on one dedicated port** — clients must speak TLS and use hostnames; one port
     serves every environment; Traefik terminates TLS with the edge's certificate, synced one
     way on a timer ([0005](0005-certificates-dns01-and-tls-modes.md)). Termination, not
     passthrough: passthrough needs a certificate per backend.
  3. **Named per-port TCP entrypoints** bound to a specific address. Without TLS there is nothing
     to route on — a non-TLS TCP router can only match `HostSNI(*)` — so one port serves one
     backend. Entrypoint names are a contract with the application's route objects; a mismatch
     silently creates no router.
  4. **NodePort only as a stopgap:** the whole 30000–32767 range is all-or-nothing and the
     firewall cannot filter it ([0007](0007-host-firewall-scope.md)).

## Consequences

- The edge stays the only door; workloads are portable and canary-ready.
- Accepted cost: Traefik upgrades and entrypoint changes recreate the pod: seconds of downtime,
  every stream dropped.
- Accepted cost: Traefik sees the host network; it is trusted like the edge.
- A hostNetwork pod that cannot bind one port does not start at all, taking every HTTP route with
  it. Opt-in TCP ports are preflighted with `ss -ltnp` for a holder that is not Traefik — check
  the process name: a stray `kubectl port-forward --address 0.0.0.0` looks exactly like a
  workload on the host.
- Helm accepts values keys a chart does not use without any error (keys move between major chart
  versions). Every chart bump re-checks the values against the chart's `values.schema.json`.

## Alternatives considered

- **hostPort + hostIP:** the chart also uses `hostIP` as the listen address *inside* the pod, so
  Traefik binds the pod's own loopback and is unreachable; firewalld reloads wipe CNI portmap
  rules; hostPort with rolling updates deadlocks on one node.
- **ingress-nginx:** its chart offers no hostIP binding, so it cannot be kept off `0.0.0.0`; and
  it is retired.
- **Envoy Gateway:** centred on LoadBalancer Services (disabled here), with less complete
  conformance at the time of evaluation.
- **k3s's bundled Traefik:** versions and configuration owned by k3s.
- **Edge → NodePort Service:** opens a second path into the cluster.

## Revisit when

- Traefik loses hostNetwork address binding or stalls on Gateway API.
- Portable SNI routing (TCPRoute/TLSRoute, listener sets) is supported by the controller: move
  the TLS entrypoint's routes to Gateway API objects; ports and certificates stay.
- More than one cluster: each gets its own loopback port — the shape this design leaves room for.
