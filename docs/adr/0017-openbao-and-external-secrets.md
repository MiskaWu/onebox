# 0017. OpenBao on the host is the source of workload secrets; External Secrets delivers them

- Status: Accepted
- Related: [0006](0006-internal-only-by-default.md), [0011](0011-shared-datastores-app-owned-databases.md), [0016](0016-gitops-central-repository.md), [0018](0018-one-oidc-issuer.md), [0021](0021-secrets-handling.md), [0025](0025-off-host-copies.md), [0026](0026-admission-policy.md)

## Context

Workloads need secrets as Kubernetes Secrets. Copying values from the platform's secrets file
into every namespace does not scale, and values must never land in a GitOps repository. The
platform's own secrets must not depend on anything the platform itself deploys. Pulling private
images needs credentials in every namespace that runs them, including namespaces the platform
has never heard of.

## Decision

**The store**

- **OpenBao runs on the host** (podman), in the same layer and lifecycle as the datastores — not
  in the cluster. A development cluster may be rebuilt at any time, and External Secrets assumes
  an external store. In-cluster clients reach it through the edge (`bao.<domain>`): pods cannot
  reach host loopback, and the edge already provides TLS and the internal-only guard — which
  therefore must allow the pod CIDR on that vhost ([0006](0006-internal-only-by-default.md)).
- **Platform secrets stay in the inventory's `secrets.yml`,** never in OpenBao: the code that
  deploys OpenBao cannot depend on OpenBao.
- **Ownership split:** the platform owns the store, the values and the policies; applications
  declare in their GitOps repositories which keys they need and how they are shaped
  (`ExternalSecret`).
- **Auto-unseal with a static key** in a root-only file. Stated honestly: key and ciphertext sit
  on the same host, so this is no stronger at rest than the plain secrets file. The gains are
  elsewhere — dynamic delivery, audit, per-application policy, revocation, values no longer
  copied around by Ansible. Shamir unsealing would need a human after every reboot (secrets
  delivery down until someone types). The seal key is the one secret that cannot be regenerated
  or restored from data backups: it gets an off-host copy when it is created
  ([0025](0025-off-host-copies.md)).
- **Configuration is converged by Ansible** (mounts, policies, auth methods, OIDC roles), not by
  the server's declarative self-initialisation, which runs once and cannot be changed afterwards
  without wiping storage. Splitting the work between the two would mean two declarations of one
  thing, synchronised by hand. The root token stays in a root-only init file.
- **Integrated raft storage,** not `file`: upstream has announced moving the `file` backend and
  several auto-unseal mechanisms out of the standard binary. Before crossing such a release,
  check that the configured seal type is still built in — a store that cannot unseal stops every
  application's secret delivery.
- **External Secrets authenticates with Kubernetes auth and no stored reviewer token:** OpenBao
  validates the client's own service-account token through TokenReview, which needs
  `system:auth-delegator` for that service account. No long-lived static credential exists in
  the cluster or in the store — unlike token or AppRole auth, which create a "secret zero".
- **Human access via OIDC** ([0018](0018-one-oidc-issuer.md)) with a bound-claims email
  allowlist. An empty allowlist refuses to converge: otherwise anyone who can sign in to the
  identity provider would be an OpenBao administrator.
- **Path layout:** `platform/registry/<registry>/<tenant>` (image pull credentials),
  `platform/datastore/<engine>` (host-wide datastore credentials), `<tenant>/env/<tier>`
  (application secrets). The registry segment maps to exactly one registry host and is named by
  service identity, never by software name (two GitLab instances would collide). Environments
  sit under `env/` so an environment name generated from a branch can never collide with a
  sibling folder. Policies use the `+` single-segment wildcard.
- **When to isolate a secret,** ask three questions: does a leak have a different blast radius
  in the two places? who can read the namespace it lands in? can it be rotated independently?
  Isolation that needs a manual write per automatically created environment always degrades
  (someone copies the dev value) — short-lived branch environments share one path.

**Image pull credentials**

- **A `ClusterExternalSecret` selects namespaces by label** and builds a `dockerconfigjson` from
  OpenBao for every listed registry. New namespaces receive it without any platform run. It is
  fail-closed: if one registry's credential is missing, none is produced.
- **Workloads declare `imagePullSecrets` themselves.** The platform keeps no list of tenant
  namespaces and patches no service accounts — application-paced lists do not belong in the
  platform repository.
- **One switch, read by both the Argo CD and External Secrets roles,** decides who owns the pull
  secret, so two owners never overwrite each other's Secret (a failure that is very hard to
  trace). `creationPolicy: Owner` does not adopt an existing Secret of the same name — delete
  the old one when migrating.
- **The registry credential is read-only and group-scoped** (a deploy token with registry read
  only). Never a personal or administrator token: the credential is readable by every pod in a
  labelled namespace. Avoid reserved names (`gitlab-deploy-token` is injected into every CI job
  automatically).
- **Diagnostics test the layers separately:** registry reachable → credential *authenticates* →
  credential is *authorised* for the repository (a token can authenticate and carry an empty
  access list) → the in-cluster Secret matches the declared credential (compare the derived auth
  value without printing it, not just the host name). Scan every namespace for pods using
  private images without a pull secret.

## Consequences

- No static credentials in the cluster; a new namespace needs no platform run.
- Accepted cost: image pulls in *new* namespaces depend on External Secrets and OpenBao. Existing
  Secrets survive an outage (External Secrets does not delete what it created), and auto-unseal
  means a reboot needs no human.
- Accepted cost: a workload that forgets `imagePullSecrets` fails with `ImagePullBackOff`. Worse,
  node image caches can hide a wrong pull secret for days until an unrelated change restarts the
  pods — check what the workload's `image:` really points at before changing which registry the
  pull secret serves.
- Accepted cost: a group-scoped token lets any tenant namespace pull any image of that group.

## Alternatives considered

- **OpenBao in the cluster with raft replicas:** right once the cluster is long-lived production.
- **Sealed Secrets or SOPS in Git:** encrypted values still live in the GitOps repository.
- **Ansible copying values into namespaces:** application-paced lists in the platform repository.
- **Shamir unsealing; cloud KMS or transit unseal:** a human after every reboot; or a new cloud
  dependency, or a second OpenBao that has to exist before the first.
- **Per-namespace registry tokens from External Secrets generators:** needs a much broader token
  to mint them, and the generator API was still alpha — not for a boot-critical path.
- **Injecting `imagePullSecrets` by admission policy:** see [0026](0026-admission-policy.md).

## Revisit when

- The cluster becomes stateful production and the store needs high availability.
- An independent root of trust appears (HSM, cloud KMS, a separate transit store): upgrading
  the seal is then a pure improvement.
- Tenants must not pull each other's images: per-namespace credentials (part of the tenant
  model, not a smaller token).
- Workloads regularly forget `imagePullSecrets`: [0026](0026-admission-policy.md).
