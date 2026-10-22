# gitlab_runner — CI on the host: shell executor + rootless podman

A GitLab Runner installed from GitLab's package repository and run by host systemd, with the
**shell executor**: job scripts run as the `gitlab-runner` account on the host and build
images with that account's **rootless podman**. It is registered as an **instance runner**
of the GitLab on this platform (`gitlab_runner_url`, default `https://<gitlab_hostname>`).

Why not in a container: the runner's job *is* to use the host's container engine. Putting it
in a container means podman-in-podman, or handing it the host's podman socket — which is
handing it the host. The isolation happens one level down instead, in the rootless podman
containers the jobs start.

## Security model — read before widening anything

**Every pipeline that reaches this runner runs its code on this host**, as `gitlab-runner`.
The guardrails, all of which are needed:

1. **A dedicated, unprivileged account.** Never add it to `wheel`/`sudo`, `docker`, `adm`,
   `systemd-journal`, `disk` or the operators group — each turns "any pipeline" into root,
   the logs, raw disks or an operator. The role checks the account's groups against
   `gitlab_runner_forbidden_groups` on every converge and fails if one appears.
2. **Builds run in rootless podman**, inside a user namespace: root in a build container is
   an unprivileged id range on the host.
3. **No fork merge-request pipelines.** A merge request from a fork would run the fork's code
   here. Keep "Run pipelines in the parent project for merge requests from forks" off and
   don't let untrusted people create projects or edit CI configuration on this GitLab — that
   membership, not the runner's tags, is the real boundary. Tags are routing, not security:
   anyone who can write `tags: [linux, amd64]` in a project lands on this runner.
4. **Leave "Run untagged jobs" off**, so nothing ends up on the host without asking for it.

What the account *can* reach is worth knowing: everything bound to `127.0.0.1` on this host
is local to it (published container ports, the Caddy admin socket is root-only though), and
everything world-readable. Datastores need their passwords; keep it that way. Read-only
access to this repository's checkout (non-secret parts) is accepted.

## Creating the runner (in GitLab — the token comes from there)

The current registration flow creates the runner in GitLab and gives you an authentication
token (`glrt-…`); `gitlab-runner register` and registration tokens are not used. The role
writes `config.toml` directly — that is all `register` would have done.

1. Admin → CI/CD → Runners → **New instance runner**.
2. **Tags**: base tags are permanent facts about the machine: `linux`, `amd64`. Add capability
   tags (`image-build` — "has a native container engine"). Never make a tag that might move
   to another runner part of every project's default `tags:` — when it moves, every
   project breaks at once. No project or environment names in tags, no `shared`
   (sounds like GitLab's old "shared runner" term), no `self-hosted` (says nothing here).
   Matching is AND: a runner with more tags than a job asks for still takes it; a job with
   a tag no runner has stays pending forever.
3. **Run untagged jobs**: off. **Protected**: as you like.
4. **Maximum job timeout**: set one.
5. **No token expiry.** On rotation the runner writes the new token into `config.toml`, the
   next converge writes the old one back, and the runner goes offline.
6. Description: `<environment>-linux-shell` (the list shows this; `gitlab_runner_name` in
   `config.toml` is informational only).
7. Copy the `glrt-…` token: `make secrets-set KEY=gitlab_runner_token`, then
   `sudo make gitlab-runner`.

The role asks GitLab whether it accepts the token (`POST /api/v4/runners/verify`) and fails
on a 403 — a token from another instance or a deleted runner otherwise only shows as 403s in
the runner log, followed by the runner disabling itself for an hour.

## Variables

See `defaults/main.yml` — every knob is documented there. The important ones:
`gitlab_runner_version` (pinned, same minor as GitLab), `gitlab_runner_url`,
`gitlab_runner_concurrent` / `_request_concurrency`, `gitlab_runner_home` /
`_home_must_be_mount`, `gitlab_runner_subid_start` / `_count`, `gitlab_runner_pasta_*`,
`gitlab_runner_prune_*`, `gitlab_runner_tls_ca_file`, `gitlab_runner_binfmt_enabled`.

Secret: `gitlab_runner_token`.

## How it is deployed (and why in this order)

1. **The account before the package.** The package's post-install script creates
   `gitlab-runner` only if it does not exist, with a home of its choosing, and generates the
   systemd unit from that home. Creating the account first means the inventory decides.
   (The name is fixed: the script knows no other.)
2. **Rootless podman prerequisites**: a subordinate uid/gid range (checked against every other
   account's range — overlapping ranges would make two accounts share file ownership inside
   containers), **linger** (otherwise `/run/user/<uid>` only exists during a login, i.e.
   never), the user manager actually running (linger can be enabled while `user@<uid>` is
   stopped, e.g. after `loginctl terminate-user`; rootless podman then falls back to cgroupfs),
   `podman system migrate` when the range changed.
3. **The pasta address** (below), with clean-up of stale network state.
4. **Repository → `config.toml` → package**, so the service the post-install script starts
   already has our configuration. Installed with `NO_DOCKER_PRUNE=1` (below).
5. **A drop-in owns `ExecStart`** of `gitlab-runner.service` (below), plus
   `RequiresMountsFor=<home>`; a prune timer; the service.

`config.toml` changes need no restart: the runner re-reads it within seconds, without
interrupting jobs. Only a changed unit restarts the service.

## Pitfalls handled here

- **The post-install script prunes the host's podman.** It runs `clear-docker-cache prune`,
  which falls back to *podman* when docker is absent — as root, so against the platform's
  rootful store — and its `network prune` is unfiltered: any podman network without a running
  container (e.g. `onebox-data` while the databases restart) would be deleted. The role
  installs and upgrades with `NO_DOCKER_PRUNE=1`. If you ever install the package by hand on
  this host, do the same.
- **The home is baked into the unit.** `gitlab-runner install` writes
  `--working-directory <home>` into `ExecStart` when the package is installed; change the home
  later and the service dies with "chdir …: no such file or directory". The drop-in
  `gitlab-runner.service.d/10-onebox.conf` resets `ExecStart` from the inventory, so the
  unit follows the variable and package upgrades cannot undo it.
- **Pinned versions need both packages.** `gitlab-runner` depends on
  `gitlab-runner-helper-images` *of exactly the same version*; apt would pick the newest
  helper-images package and refuse. Both are pinned together.
- **pasta copies the host's address into containers.** A job container that resolves
  `gitlab.<domain>` to the host's own address connects to *itself* and fails in milliseconds.
  The containers.conf drop-in in the runner's home gives containers a private address
  (`gitlab_runner_pasta_address`, asserted not to overlap the LAN, podman or k3s networks),
  so the host is "another machine" again, reached through pasta's NAT — for every service of
  this host at once, and for containers started by job scripts as well as any future
  container-based executor. Two follow-up traps, both converged:
  - pasta for the rootless network namespace is long-lived; one started before the change
    keeps serving bridge-networked containers with the old setup. Processes whose command
    line lacks the configured address are stopped.
  - stopping pasta leaves podman's bookkeeping of that namespace behind; podman then keeps
    attaching containers to a namespace with no way out (pulls work, the first connection of
    the job is refused, the runner reports a "zombie container"). Bookkeeping without a live
    pasta is removed; podman rebuilds it.
  Verify with both modes (a plain `podman run` uses pasta directly, job containers use the
  bridge): `sudo -iu gitlab-runner podman run --rm docker.io/curlimages/curl -sS -o /dev/null
  -w '%{http_code}\n' https://gitlab.<domain>/users/sign_in`, and again with `--network podman`.
- **The home grows** (image layers, build directories, caches). Put it on a volume of its own
  (`roles/storage`) so a runaway cache fills that volume, not `/var` with the journal and the
  rootful container store; set `gitlab_runner_home_must_be_mount: true` so a volume that
  failed to mount stops the converge instead of a fresh home appearing on `/var`. Never
  `noexec` (rootless podman: "exec user process caused: permission denied" — asserted);
  `nodev,nosuid` are fine. Not on spinning disks: unpacking layers is small random I/O.
  Do not move the storage with `rootless_storage_path` either — the store follows the home;
  a second setting only drifts.
- **SELinux and a home outside `/home`.** The policy labels rootless container storage only
  below `/home/<user>`; under `/var/lib` it becomes `var_lib_t` and containers fail. The role
  adds a file-context *equivalence* (`semanage fcontext -a -e /home/gitlab-runner <home>`; not
  `chcon`, which `restorecon` undoes) and relabels once. It counts only "Relabeled" lines as
  changes: restorecon also reports files podman labelled `container_file_t`, which it rightly
  leaves alone.
- **Pruning.** Jobs keep their layer cache on purpose; nothing cleans up after them. The
  timer runs `podman system prune --filter until=<gitlab_runner_prune_until>` weekly — without
  `--all` by default, which would also drop base images between builds.
- **Concurrency** is limited by memory on a shared host, not by cores: CI starving GitLab
  looks like a slow GitLab, not like CI. Parallel builds also share one podman store with a
  global lock, so two slots give overlap (one job pushes while another compiles), not double
  speed. `request_concurrency` is the number of parallel long-poll requests for jobs — keep
  it ≥ `concurrent`, or free slots stay empty.

## Multi-arch builds (`gitlab_runner_binfmt_enabled`)

`podman build --platform linux/arm64` runs foreign `RUN` steps through QEMU user-mode
emulation registered in `binfmt_misc`. The registration needs the **F (fix-binary) flag**:
the kernel then opens the emulator once at registration, and containers — whose mount
namespace contains no emulator — can still use it. Check with
`grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64` (must contain `F`).

- **Debian/Ubuntu**: the role installs `qemu-user-static` (static emulators, F flag,
  registered by `systemd-binfmt`).
- **RHEL family**: there is **no** `qemu-user-static` in RHEL 9/10, AppStream, CRB or EPEL, so
  the role refuses the option there. Options, in order of preference: build arm64 images on
  an arm64 runner; register emulators from a container image at boot
  (`podman run --rm --privileged <binfmt image> --install arm64`, pinned by digest, as a
  oneshot unit — registrations do not survive a reboot); or install a single signed,
  statically linked emulator package from another distribution (without adding its
  repository). Kernels from 6.7 on make `binfmt_misc` per user namespace, which changes what
  rootless containers see — test after kernel upgrades. If a build dies with "illegal
  instruction", try `QEMU_CPU=max`.

## Operations

| Suggested target | Command |
|---|---|
| `make gitlab-runner-status` | `systemctl status gitlab-runner gitlab-runner-prune.timer`; `sudo -iu gitlab-runner podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphRoot}}'` (must say `true`); `loginctl show-user gitlab-runner -p Linger`; `df -h <home>` |
| `make gitlab-runner-logs` | `journalctl -u gitlab-runner -f` |
| `make gitlab-runner-prune` | `systemctl start gitlab-runner-prune.service` |

**Replacing the token**: GitLab has no in-place reset of a runner authentication token, and
anyone holding a leaked one can impersonate the runner and receive jobs (with their source
and CI variables). So: delete the runner in GitLab (the old token dies immediately), create a
new one with the same settings, `make secrets-set KEY=gitlab_runner_token`,
`sudo make gitlab-runner`. Moving to another GitLab instance: change `gitlab_runner_url`
*and* the token together. A restart (`systemctl restart gitlab-runner`) clears the one-hour
self-disable after 403s.

**Disk full**: check the timer ran (`systemctl list-timers gitlab-runner-prune.timer`), lower
`gitlab_runner_prune_until`, consider `gitlab_runner_prune_all_images`, or grow the volume
(roles/storage README).

**Moving the home**: stop the runner, mount the new volume at the new path, set
`gitlab_runner_home`, converge (the drop-in follows). The image store does not need to be
copied — it is a cache, and podman records absolute storage paths in its database, so a
copied store at a new path breaks; the first builds are just slower.

## Later: a container executor next to this one

Most jobs (tests, linters) do not need the host's container engine. A second runner with the
docker executor pointed at this account's rootless podman API socket would run them in
containers, where `127.0.0.1` is the container's own loopback, not the host's. Give the base
tags (`linux`, `amd64`) to that runner only and leave this one with `image-build`: jobs then
land on the host only when they ask for it, and if the container runner is down they wait
instead of falling back to the host. Order of the switch: new runner up and taking jobs
first, then shrink this one's tags. **Never mount the podman or docker socket into job
containers** — that is the host's engine in a pipeline's hands; a job that needs it is an
`image-build` job and belongs on this runner.
