# 0026. Admission policy for workload guardrails

- Status: Proposed
- Related: [0007](0007-host-firewall-scope.md), [0015](0015-loopback-cluster-gateway.md), [0017](0017-openbao-and-external-secrets.md)

## Context

Two workload rules are enforced only by documentation today:

- Workloads must declare `imagePullSecrets` ([0017](0017-openbao-and-external-secrets.md)).
  Kubernetes has no "namespace default pull secret"; the Secret is delivered to the namespace
  but nothing attaches it to pods. Forgetting it fails with `ImagePullBackOff`.
- Workloads must not use `hostNetwork`, `hostPort` or `NodePort`. NodePorts bypass the edge and
  the firewall ([0007](0007-host-firewall-scope.md)); a stray host port can stop the hostNetwork
  gateway from binding, which takes every HTTP route down
  ([0015](0015-loopback-cluster-gateway.md)).

## Decision (proposed)

- **Validation:** use the built-in `ValidatingAdmissionPolicy` (CEL, no webhook) to reject
  `hostNetwork`, `hostPort` and `NodePort` outside platform namespaces. No extra controller, and
  no webhook in the pod creation path.
- **Mutation (only if the trigger below fires):** a policy engine such as Kyverno mutating
  *Pods* (not service accounts, so workloads with custom service accounts are covered too) in
  namespaces carrying the pull-secret label. Start with `failurePolicy: Ignore` and measure memory
  use and failure behaviour before relying on it.

## Consequences

- Validation is cheap and catches the most damaging mistake (a host port blocking the gateway).
- A mutating webhook is expensive on one node: with `Fail`, no covered pod can be created while
  the engine is down; with `Ignore`, pods start without credentials and fail with an
  `ImagePullBackOff` indistinguishable from a wrong credential. Plus several resident pods and a
  CRD-heavy component to pin and upgrade.

## Alternatives considered

- **Platform patches each namespace's default service account:** needs a platform-held list of
  tenant namespaces, and misses custom service accounts.
- **Documentation only (current state).**

## Revisit when

Accept the mutation half when any of these holds:

- manifests are produced at scale by people outside the platform team and missing pull secrets
  become real incidents;
- a second rule needs mutation or a policy engine anyway;
- the cluster has more than one node, so a webhook outage no longer stops the whole cluster.
