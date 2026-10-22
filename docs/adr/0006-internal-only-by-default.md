# 0006. Internal-only by default at the edge, with explicit exceptions

- Status: Accepted
- Related: [0004](0004-host-native-edge-proxy.md), [0007](0007-host-firewall-scope.md), [0018](0018-one-oidc-issuer.md), [0020](0020-remote-access-mesh-vpn.md)

## Context

The forge, the identity provider, the secrets UI and the GitOps UI must not become reachable
from outside the LAN by accident — through a later port-forward, a VPN route, or a cloud
security group edit. All vhosts share port 443, so an L3/L4 filter cannot tell one service from
another.

## Decision

- **An L7 guard at the edge.** Every vhost imports `onebox_internal_only`, which answers 403 when
  the client address is outside `onebox_lan_cidrs`. A service is opened explicitly per entry with
  `internal_only: false`, or widened with `allow_cidrs`. The global default is
  `edge_internal_only_default: true`.
- **No bypass for HTTP.** Every service binds loopback; the edge is the only HTTP listener on a
  routable address.
- **Opening a service is a reviewable inventory line,** not a firewall side effect.
- **Naming keeps the cluster from swallowing typos.** Platform services get flat names
  (`gitlab.`, `sso.`, `bao.`, `argocd.<domain>`); cluster workloads live under a dedicated
  subtree with a catch-all (`*.apps.<domain>`). A mistyped platform name never lands in the
  cluster, and dynamic workload environments need no platform change.

## Consequences

- Forgetting to configure something leaves it locked, not exposed.
- It enforces the identity provider's real security boundary: some sign-up APIs bypass
  upstream tenant restrictions, so the network boundary is what actually protects them
  ([0018](0018-one-oidc-issuer.md)).
- Accepted cost: `remote_ip` is the TCP peer. Behind NAT with source rewriting, or behind
  another proxy, every client looks internal. Before exposing anything through such a path,
  switch the guard to the forwarded client address with explicit trusted proxies.
- Accepted cost: legitimate clients in other ranges get 403 until their range is added — VPN
  ranges, and the pod CIDR for in-cluster consumers of platform vhosts (External Secrets
  calling the secrets store, Argo CD calling the OIDC issuer).
- No firewall "hard floor" on 80/443 by default: it would also block vhosts that are
  intentionally public.

## Alternatives considered

- **Per-service firewall rules:** impossible on a shared port.
- **Open by default with a deny list:** forgetting means exposure.
- **Rely on each application's authentication:** forges and identity providers regularly ship
  vulnerabilities exploitable without authentication; exposing them commits you to patching on
  the attacker's schedule.

## Revisit when

- A legitimate client in another range gets 403: add the range; do not disable the guard.
- A service must become public: set `internal_only: false` on that entry only, and first
  re-check its own hardening (admin password rotated, self-sign-up closed, patch cadence owned).
