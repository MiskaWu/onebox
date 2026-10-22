# 0019. The CI runner runs on the host: shell executor plus rootless podman, behind guardrails

- Status: Accepted
- Related: [0004](0004-host-native-edge-proxy.md), [0010](0010-podman-quadlet-services.md), [0011](0011-shared-datastores-app-owned-databases.md), [0016](0016-gitops-central-repository.md)

## Context

CI's main job is building multi-architecture container images, which needs a real container
engine. Deployment is GitOps ([0016](0016-gitops-central-repository.md)), so CI never needs to
touch the cluster. A Kubernetes executor would need Docker-in-Docker or an in-pod builder; a
containerised runner would need the host's engine socket.

## Decision

- **GitLab Runner as a host-native service** under a dedicated `gitlab-runner` account; the
  shell executor builds with **rootless podman**. The runner is not containerised: its job is to
  use the host's engine, and putting it in a container means DinD or handing over the socket.
- **Guardrails — all of them, because the shell executor runs repository code on the host:**
  1. The runner account is in no privileged group (sudoers, operators, cluster admins); the
     secrets file and service data are unreadable to it.
  2. Builds run inside rootless containers.
  3. Fork merge-request pipelines are disabled on every project that can reach the runner. It is
     a per-project setting and new projects default to on; without it, outsiders' code runs on
     the host and the other guardrails are moot.
  4. **Two runners.** A container-executor runner (pointing at the runner user's rootless podman
     socket) carries the base tags and takes ordinary jobs. The shell runner carries only a
     capability tag (`image-build`) and is reached only by jobs that name it. A job that forgets
     its tags never lands on the bare host; if the container runner is down, jobs wait (the
     right failure direction) instead of silently running on the host. The podman socket is
     never mounted into job containers — a job that "needs" it is a build job.
  5. "Run untagged jobs" stays off.
  6. **Tags state permanent facts and capabilities** (`linux`, `amd64`, `image-build`), never
     project or environment names, never `shared` or `self-hosted` (no information, or a clash
     with GitLab's own terms). A tag that will move to another runner must not be a base tag.
     Matching is AND: extra tags on a runner cost nothing; extra tags on a job narrow it.
  7. An instance-wide runner widens the boundary from "one trusted project" to "anyone who can
     create a project". Tags are routing, not security.
- **Everything on loopback is reachable from CI.** Binding `127.0.0.1` keeps things off the
  network, not away from code running on the host. Hence the edge's admin API on a 0700 socket
  ([0004](0004-host-native-edge-proxy.md)) and authentication on every datastore
  ([0011](0011-shared-datastores-app-owned-databases.md)). When probing "does this require
  authentication?", confirm the client tool exists first — a missing binary looks exactly like
  a refused connection.
- **Rootless networking:** pasta copies the host's address into each container by default, so a
  job that connects to any host service by name or IP reaches itself and is refused within
  milliseconds. The runner user's containers get their own address range through a
  `containers.conf.d` drop-in, checked to be disjoint from the LAN, pod, service, podman and
  data networks. pasta is long-lived in the rootless network namespace: a changed setting needs
  the old process killed *and* its stale bookkeeping removed. Verify with a container on a bridge
  network — a default `podman run` takes a different path.
- **Runner home in `/var/lib/gitlab-runner` on its own volume:** image-layer caches grow there,
  not in `/home` or `/var`. The package bakes the working directory into its unit at install
  time, so the account is created *before* the package is installed; under SELinux the new home
  gets a file-context equivalence to `/home/<user>` (not `chcon`, which `restorecon` undoes); a
  `noexec` mount breaks rootless podman; lingering and a running user manager are part of
  convergence. Subordinate UID/GID ranges are allocated far from human users' ranges.
- **URL and token must come from the same forge.** A mismatch returns 403, after which the runner
  disables itself for an hour while its status still reads "active". The forge's runner verify
  endpoint tells which instance issued a token.
- Concurrency rises only after the container runner exists — otherwise "who can run code on the
  host" and "how many at once" grow together.
- Runner token expiry stays off: rotation writes the new token into a file Ansible manages, and
  the next converge would put the old one back.

## Consequences

- Fast native builds with multi-architecture support; no in-cluster build machinery.
- Accepted risk: repository code runs on the platform host; the guardrails reduce, not remove,
  that risk. The platform checkout's non-secret files are readable by the runner account.
- Accepted cost: the forge's availability is CI's availability.

## Alternatives considered

- **Kubernetes executor:** needs DinD, kaniko or buildah in pods, plus cluster capacity for
  builds.
- **Container executor only:** build jobs would need the engine socket inside the job.
- **Runner in a container:** DinD or socket hand-over.

## Revisit when

- Untrusted accounts (contractors, external collaborators) can create projects: switch to
  group- or project-scoped runners and treat every "it's only colleagues" assumption as void.
- Heavy builds (large native toolchains, long packaging jobs) arrive: give them their own
  machines, runners and tags; do not reuse this runner's settings.
