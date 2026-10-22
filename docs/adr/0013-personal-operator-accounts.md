# 0013. Personal operator accounts, sudo with a password, explicit on- and offboarding

- Status: Accepted
- Related: [0009](0009-guarded-irreversible-changes.md), [0012](0012-datastore-reachability.md), [0021](0021-secrets-handling.md)

## Context

Several people operate the host, and destructive `make` targets run as root. The team needs to
know who ran what and to revoke one person without disturbing the others. Automation and AI
assistants also execute commands on behalf of operators.

## Decision

- **One Linux account per person,** with their own SSH key and sudo password. No shared logins.
  Names are lowercase `[a-z][a-z0-9-]*`: Linux names are case-sensitive and `useradd` accepts
  capitals, so `Alice` and `alice` are different users and a mismatch makes convergence skip the
  person silently. Convergence reports "declared but missing" accounts.
- **Public keys are declared in the inventory** (version-controlled: they are public, and the list
  is what rebuilds everyone's access after a reinstall). Nobody generates or transports a private
  key for someone else; fingerprints are confirmed over a second channel.
- **Baseline convergence manages existing accounts only.** Creating an account is an explicit
  command — a typo in a list must not silently create a user.
- **Passwords never pass through Ansible** (logs, temp files); generating and prompting are
  separate targets.
- **sudo keeps its password.** The gate is not against the operator (sudo is root); it stops
  non-human actors from reaching root without a recent human authorisation: an automation bug, a
  prompt-injected assistant, a compromised user shell. A scoped `NOPASSWD` for the deploy script
  is theatre when the same actor can edit the playbooks that script runs. How long a sudo
  authentication lasts is personal ergonomics, kept out of IaC.
- **Offboarding has two stages.** *Remove* is reversible and immediate: drop groups and keys, lock
  the password, expire the account (console logins fail too), end sessions, keep the home.
  *Purge* deletes account and home. Guards: refuse while the person is still declared (the next
  converge would add them back); refuse to remove yourself. The output lists every secret key
  name to rotate. Sessions are ended through logind, never `pkill -u`: rootful containers run as
  host UIDs ([0010](0010-podman-quadlet-services.md)).
- **Break-glass accounts are console-only by structure,** not by intent: sshd `DenyUsers` *and*
  no `authorized_keys` (if the sshd drop-in is ever lost, leftover keys would silently restore
  remote access). The list is asserted disjoint from the operators list.
- **The repository checkout lives in a neutral path** (`/opt/<repo>`), owned by an operators group
  with setgid; service data stays root-only. Git's `safe.directory` exceptions are issued per
  declared operator, not system-wide.
- Forcing a password change at first login works for interactive sessions only; never apply it to
  automation accounts.

## Consequences

- Every root action maps to a person; revoking one person is deleting one account.
- At-rest secret encryption does not protect against current operators: anyone with root can
  read rendered configuration at runtime. Offboarding therefore always rotates the secrets the
  person could reach ([0021](0021-secrets-handling.md)).
- Accepted cost: onboarding has a few explicit steps.

## Alternatives considered

- **A shared admin account:** no audit trail; revocation means rotating everything.
- **`NOPASSWD` sudo:** whoever drives the shell is root, including automation fed untrusted input.
- **Scoped `NOPASSWD` for the deploy script:** no protection when the same actor can change what
  the script runs.
- **A separate deploy identity that only runs reviewed commits:** the right answer for unattended
  automation, but heavy, and a bootstrap loop when the reviewer is the self-hosted forge.

## Revisit when

- Unattended convergence becomes a requirement: introduce the separate deploy identity; do not
  widen sudo.
- Machine accounts appear: they follow different rules (no forced password change, possibly no
  operators group).
