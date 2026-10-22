# 0025. Off-host copies of the repository, the secrets and the unrecoverable keys

- Status: Proposed
- Related: [0001](0001-one-host-per-environment-one-repository.md), [0011](0011-shared-datastores-app-owned-databases.md), [0017](0017-openbao-and-external-secrets.md), [0021](0021-secrets-handling.md)

## Context

One host holds everything needed to rebuild itself, and some of it exists nowhere else:

- the platform repository, if its source of truth is the forge this repository deploys — a
  bootstrap loop: losing the host loses the code that rebuilds it;
- `secrets.yml`, gitignored and therefore never backed up or shared;
- the secrets store's seal key (cannot be regenerated; data backups cannot be decrypted without
  it) and recovery key;
- datastore dumps, if they land on a disk inside the same machine.

Backups that sit next to the data protect against operator error, not against losing the host
or the site.

## Decision (proposed)

1. **Repository:** keep the source of truth outside the host it manages, or ship a `git bundle`
   (one file, the complete repository) off-host on a schedule.
2. **Secrets in version control, encrypted:** ansible-vault with a random 25+ character password
   from a password manager, or SOPS with age ([0021](0021-secrets-handling.md)). Add secret
   scanning before commit and in CI so plaintext can never be pushed, and change the ignore
   rule from "never commit secrets.yml" to "never commit plaintext".
3. **Unrecoverable keys** (seal key, recovery key, vault password) go into a password manager the
   team shares. A copy on a NAS is acceptable as an interim step only if encrypted first — shares,
   snapshots and cloud sync replicate plaintext to places nobody planned — and it does not
   protect against losing the site. A password manager self-hosted on the same host protects
   nothing.
4. **Datastore backups:** scheduled (a systemd timer the platform converges), content-verified
   (archive integrity and the dump's completion marker — a backup that "looks done" is worse than
   none), rotated, then copied off-host encrypted. Point-in-time recovery only when the recovery
   point objective demands it.
5. **Forge backups include the forge's own secrets file,** which is not part of its backup archive
   and without which encrypted settings (2FA, CI variables) cannot be restored.

## Consequences

- Losing the host becomes an inconvenience instead of a rebuild from memory.
- Costs: an external destination to choose and pay for; the vault password or age key becomes a
  new item that must itself survive; encrypted dumps need key management.

## Alternatives considered

- **Cloud KMS auto-unseal for the secrets store:** removes the seal key from human custody — but
  recovery keys still need a home, so the password manager is needed anyway.
- **Accepting the risk:** reasonable for a lab; not for a team platform.

## Revisit when

To be accepted when an off-host destination and a password manager are chosen. Decide the
repository's home before a second site or host appears, and whenever a policy requires code to
live in a managed external service.
