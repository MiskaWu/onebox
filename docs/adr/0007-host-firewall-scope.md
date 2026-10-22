# 0007. The host firewall only guards locally delivered packets; container rules must survive reloads

- Status: Accepted
- Related: [0006](0006-internal-only-by-default.md), [0008](0008-git-over-ssh-owns-port-22.md), [0012](0012-datastore-reachability.md), [0015](0015-loopback-cluster-gateway.md), [0022](0022-reported-success-did-nothing.md)

## Context

It is natural to assume that firewalld protects container ports: "port not opened → blocked".
Measured from another LAN machine, a datastore published on the host's LAN address was
reachable with no firewall rule allowing it, and so were Kubernetes NodePorts. `firewall-cmd`
reported success for source-restricted rules on those ports and listed them afterwards; they
were simply never on the packet path.

Separately, after a `firewall-cmd --reload`, containers could no longer open new outbound
connections ("no route to host", even DNS to the network gateway) while existing connections
kept working.

## Decision

- **Rule of thumb: a port is protected by the host firewall only if a local socket accepts the
  packet** (INPUT path): the edge on 80/443, admin sshd, the Kubernetes API server, kubelet,
  hostNetwork listeners. Podman published ports and NodePorts are DNAT'd in prerouting and
  traverse FORWARD. firewalld's port, service and rich rules live on INPUT, and its FORWARD
  chain accepts `ct status dnat` before zones or policies are evaluated — so neither zones nor
  policies can filter DNAT'd traffic.
- **Therefore bind, don't filter.** Containers publish on `127.0.0.1`. When a LAN binding is
  removed, a LAN packet to that port is no longer DNAT'd: it reaches INPUT, finds no socket and
  no allow rule, and is rejected. Two layers return with zero rules to maintain. Any
  non-loopback publish is an explicit variable with a documented reason
  ([0008](0008-git-over-ssh-owns-port-22.md), [0015](0015-loopback-cluster-gateway.md)).
- **No hand-written nftables walls in front of DNAT.** A wall that fails silently (renamed
  interface, forgotten table) looks exactly like no wall.
- **Rules that look protective but are not get removed,** not left behind to mislead.
- **Firewall backend is a provider:** `common_firewall_backend: firewalld | none` (cloud security
  groups or an external firewall).
- **Re-apply container rules after every reload.** `firewall-cmd --reload` rebuilds from the
  permanent configuration and drops netavark's runtime rules (for example container subnets in
  the trusted zone). Established flows survive on conntrack, which is why only new outbound
  connections fail. `common` enables netavark's `netavark-firewalld-reload.service`, which
  listens for firewalld reloads and re-applies the rules — for reloads from any source (a
  handler, an operator, a package update). Where the unit is missing, the role warns; the
  emergency fix is `podman network reload --all`. The same class of loss hits CNI portmap
  hostPort rules in k3s, with no repair unit — one reason the cluster gateway uses hostNetwork.

## Consequences

- Protection that cannot drift, because it is a property of where sockets are bound.
- Accepted cost: ports that must be LAN-reachable through DNAT (git-over-SSH on 22, opt-in raw
  TCP) cannot be source-restricted by firewalld. Application authentication is the only
  control there.
- The shared `firewall_open.yml` helper is ensure-present only. Removing an entry does not close
  the port; status targets should flag allowed ports that no longer have an owner.

## Alternatives considered

- **firewalld policies with an ingress zone** or `--remove-forward` on the zone: never evaluated
  for DNAT'd packets.
- **A separate nftables table hooked before DNAT:** works until an interface name changes or
  someone forgets it exists; then it fails silently.
- **Calling `podman network reload --all` after each reload in every role:** only covers reloads
  Ansible triggers, and every new reload site must remember it.

## Revisit when

- The host moves to plain nftables without firewalld: re-derive the enforcement point and enable
  netavark's nftables reload unit instead.
- firewalld changes where DNAT'd traffic is accepted.
- Datastore traffic crosses hosts: protocol-level TLS becomes required, not optional.
