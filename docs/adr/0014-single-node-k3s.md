# 0014. k3s, single node, as the workload runtime

- Status: Accepted
- Related: [0001](0001-one-host-per-environment-one-repository.md), [0002](0002-ansible-core-only.md), [0012](0012-datastore-reachability.md), [0015](0015-loopback-cluster-gateway.md)

## Context

Application workloads want what Kubernetes gives: rolling updates, self-healing, Helm charts,
GitOps, and parity with how production runs elsewhere. There is one host and a small team; the
control plane must not eat the machine.

## Decision

- **k3s, one server node, embedded SQLite** (etcd adds nothing on one node).
- `--disable traefik`: the bundled ingress is versioned and configured by k3s and claims 80/443
  through its service load balancer; we ship our own pinned gateway on loopback instead
  ([0015](0015-loopback-cluster-gateway.md)). `--disable servicelb`: all traffic enters through
  the edge. CoreDNS, local-path storage, metrics-server and flannel stay.
- **One cluster per environment host** ([0001](0001-one-host-per-environment-one-repository.md)).
- **The API server is not exposed to the LAN.** It is a host-native listener, so the firewall
  really protects it ([0007](0007-host-firewall-scope.md)); remote `kubectl` goes through an SSH
  tunnel ([0012](0012-datastore-reachability.md)).
- **Access by group, not by copied kubeconfigs.** k3s writes the admin kubeconfig owned by
  `root:<admin group>` with mode 0640, and the configuration directories are group-traversable;
  members use their own accounts. Membership equals cluster-admin. Per-user copies are avoided:
  k3s rotates its certificates and copies silently expire.
- **Cluster objects through the auto-deploy directory:** `HelmChart` objects and plain manifests
  rendered to `/var/lib/rancher/k3s/server/manifests/onebox-<name>.yaml`, installed by k3s's
  helm-controller ([0002](0002-ansible-core-only.md)). Rendered manifests are validated with
  `kubeconform -strict` in tests.
- **Deterministic install:** pin the exact k3s release and the binary directory (the install
  script falls back to another directory when the default is not writable); fetch the install
  script only when installing and delete it afterwards.
- With firewalld, the pod and service CIDRs join the trusted zone (the standard coexistence
  setting; it does not expose anything to the LAN).

## Consequences

- A full Kubernetes API for roughly 1 GB of overhead.
- Accepted cost: one node means a k3s upgrade or a host reboot is a full outage, and the
  hostNetwork gateway leaves a few seconds' gap on its own upgrades.
- Accepted cost: chart installs and upgrades need the chart repository to be reachable.

## Alternatives considered

- **kubeadm:** built for multi-node high availability; on one node it is etcd operations and a
  heavier control plane for nothing.
- **k0s:** same positioning, no advantage here.
- **RKE2:** CIS/FIPS-oriented hardening, heavier, etcd by default. A good choice for a dedicated,
  hardened production host — not for a general platform host.
- **Plain Quadlet for applications:** no rolling updates, self-healing, Helm or production parity.

## Revisit when

- A node must be added: switch to embedded etcd (`--cluster-init`), open 6443/tcp, 8472/udp
  (flannel VXLAN) and 10250/tcp between nodes, add agent join, taint the server for stateful
  workloads only, and put TLS on datastore protocols ([0012](0012-datastore-reachability.md)).
- A hardened production host is built: evaluate RKE2 there.
