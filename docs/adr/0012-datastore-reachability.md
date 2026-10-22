# 0012. Nobody reaches datastores over the LAN: pods use the data network, people use SSH tunnels

- Status: Accepted
- Related: [0007](0007-host-firewall-scope.md), [0011](0011-shared-datastores-app-owned-databases.md), [0013](0013-personal-operator-accounts.md), [0016](0016-gitops-central-repository.md)

## Context

Kubernetes pods live in their own network namespace and cannot reach the host's loopback, where
the datastores publish. The obvious fix — publish the datastores on the host's LAN address and
point pods at a DNS name through an `ExternalName` Service — turned out to remove both layers of
protection at once: the published ports are DNAT'd and bypass the firewall
([0007](0007-host-firewall-scope.md)), and database traffic without TLS crossed the LAN in
clear. People also want database GUIs on their laptops.

## Decision

- **Datastores publish only on `127.0.0.1`** for host tools, and live on the data network with
  fixed container addresses. Publishing a datastore on a routable address is an explicit,
  per-engine exception, off by default.
- **Pods route to the data-network addresses** (pod → CNI bridge → host routing → podman
  bridge). Workloads address a datastore by a stable Service name defined as a *selectorless
  Service plus an EndpointSlice* pointing at the fixed address. The application's DSN is the
  same string on podman and in Kubernetes (`postgres:5432`), and no IP appears in application
  configuration. This path never touches a published port, so DNAT behaviour is irrelevant.
- **Argo CD must be allowed to manage EndpointSlices.** Recent Argo CD releases exclude
  `Endpoints` and `EndpointSlice` by default; an excluded kind is treated as nonexistent — not
  applied, not tracked, not diffed — so the application shows Synced and Healthy while the
  slice does not exist. The platform overrides the exclusion list to allow `EndpointSlice`
  (core `Endpoints` stays excluded). Hard prerequisite: **annotation-based resource tracking.**
  The EndpointSlice controller copies a Service's labels onto its generated slices; with label
  tracking, the generated slices of every tracked Service would be pruned and recreated in a
  loop across the cluster. Because the override replaces an upstream list, a version tripwire
  forces a re-comparison with the chart's shipped list on every chart bump
  ([0023](0023-version-pinning.md)).
- **People use SSH tunnels** to the host's loopback ports through the admin sshd
  (`ssh -p <admin port> -L 5432:127.0.0.1:5432 you@host`). Database GUIs store the tunnel in the
  connection profile. The Kubernetes API is reached the same way; 6443 is not opened to the LAN.
- **GUI tools without built-in authentication run on the person's laptop over a tunnel,** never
  as a hosted vhost. A hosted copy would still bind loopback for the edge, so it adds only a LAN
  URL — and lowers the bar from "has a host SSH account" to "is on the LAN" — while adding no
  capability.
- **Redis is not announced on another address:** its announce address also drives the cluster
  bus; changing it would route the cluster's own traffic through host hairpin NAT.

## Consequences

- No plaintext datastore traffic on the LAN. Human access inherits SSH's authentication,
  encryption, audit log and revocation instead of re-implementing them per engine.
- The same application configuration works in podman and in Kubernetes.
- Accepted cost: the data-network subnet and the datastore addresses are now a contract.
- Accepted cost: the Argo CD exclusion override must be maintained (tripwire).
- Accepted cost: GUI tools must use "host + port" mode so the tunnel can rewrite the target; URL
  modes are used verbatim and connect to the laptop's own localhost.
- A verification that matters: the server's view of its clients (`pg_stat_activity.client_addr`)
  is the only reliable answer to "is everyone really using the tunnel?" — a direct LAN
  connection keeps its source address, a tunnelled one shows the host.

## Alternatives considered

- **LAN publish + `ExternalName` + DNS:** firewall bypass, plaintext on the LAN, and a co-located
  resource resolved through external DNS.
- **In-cluster DNS overrides + `ExternalName`:** split-horizon DNS — one name, different answers
  inside and outside — is a harder class of confusion to debug.
- **hostNetwork pods:** give up pod network isolation.
- **Binding datastores to the CNI bridge address:** ties the shared layer to one cluster's CIDR
  and its start order.
- **An L4 proxy in front of PostgreSQL:** PostgreSQL negotiates TLS inside its own protocol; a
  proxy adds nothing.
- **Datastore TLS for direct human access:** per-engine certificates and renewal (non-HTTP, so
  the edge's ACME does not help) to rebuild what SSH already provides.

## Revisit when

- A consumer that is neither on the host nor able to use SSH appears: add a per-source exception
  together with datastore TLS.
- The cluster gains nodes: traffic to the data network crosses hosts; TLS becomes required.
- Argo CD tracking switches back to labels: put `EndpointSlice` back into the exclusions first.
- Follow-up (proposed): a restricted tunnel group in sshd (`Match Group` with
  `AllowTcpForwarding local`, `PermitOpen` listing only datastore loopback ports, `PermitTTY no`,
  `ForceCommand /usr/bin/false`) so database access no longer implies a shell. The drop-in must
  end with `Match all`: distributions put the `Include` at the top of `sshd_config`, so a
  trailing `Match` block would capture the rest of the main configuration.
