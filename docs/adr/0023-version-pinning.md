# 0023. Pin every version, review bumps by explicit criteria

- Status: Accepted
- Related: [0010](0010-podman-quadlet-services.md), [0012](0012-datastore-reachability.md), [0015](0015-loopback-cluster-gateway.md), [0017](0017-openbao-and-external-secrets.md)

## Context

Floating tags make two converges of the same commit produce different hosts. Unattended updates
restart stateful services at random times. Pinning instead creates a duty: someone must decide
when and how far to move each pin.

## Decision

- **Pin everything** — container images (tag, and digest where possible), Helm charts, binaries,
  CRD bundles, plugins, the CI check toolchain — by version **and** checksum when upstream
  publishes one (or a checksum computed once on download). Never write a version that was not
  verified to exist. Data-layer engines follow their long-term-support lines.
- **No auto-update** ([0010](0010-podman-quadlet-services.md)); bumps are reviewed commits,
  previewed with `make check TAGS=<component>`, one component at a time.
- **Review criteria for a bump:**
  1. *Latest is not automatically right.* If the security fixes you need were also released on
     your current minor's newest patch, take the patch rather than jumping a minor.
  2. *Bumping before first deploy is free.* Nothing to migrate, nothing to restart — the best
     moment to move a pin is before its first apply.
  3. *Read the project's own cadence.* Some projects publish a new minor for every merged batch
     (continuous delivery, not semantic versioning). Judge risk by breaking changes and schema
     migrations in the release notes, not by how many numbers apart two versions are.
  4. *Sort numerically, not lexically:* `8.10.0` is newer than `8.8.0`.
- **Tripwires where the platform overrides an upstream default wholesale** (for example a list
  that replaces the chart's shipped list): record the upstream version last compared, and assert
  before deploying that it equals the deployed version. A silent drift becomes a loud stop. It
  is a reminder, not a real check — and it deliberately avoids fetching upstream during
  convergence, which would make offline converges fail.
- **Upgrade tripwires for announced removals** (features moving out of a standard binary,
  storage backends being dropped, API versions no longer served) are written next to the pin
  and checked before crossing that version.

## Consequences

- Deterministic hosts; rendered files and validators test exactly what will run.
- Accepted cost: security fixes wait for a human; somebody owns a periodic bump review.

## Alternatives considered

- **Floating tags or auto-update:** non-deterministic restarts of stateful services.
- **A dependency bot opening bump requests:** compatible with this decision and a good addition
  later; it still needs the criteria above to review its proposals.

## Revisit when

- A dependency bot is introduced (keep the criteria; automate the proposals).
- The host gains public exposure and patch latency becomes the dominant risk.
