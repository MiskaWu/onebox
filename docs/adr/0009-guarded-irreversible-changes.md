# 0009. Changes that can lock people out or destroy data are staged and guarded

- Status: Accepted
- Related: [0003](0003-make-is-the-operator-interface.md), [0008](0008-git-over-ssh-owns-port-22.md), [0013](0013-personal-operator-accounts.md), [0018](0018-one-oidc-issuer.md)

## Context

Idempotent convergence assumes that a wrong run can be fixed by a better run. That assumption
fails for a small set of changes: moving the SSH port the operator is connected on, disabling a
local admin before single sign-on works, revoking the last administrator, formatting disks,
wiping datastores, removing people. After those, the next run may not be possible at all.

## Decision

These patterns are mandatory for such changes:

1. **Prove the new path before removing the old one, with evidence rather than probes.** For the
   sshd port: an *established* sshd session on the new port is proof it works. If there is none
   but someone is connected on the old port, sshd listens on both, and the run prints "open a
   second terminal on the new port, then run again". With no SSH session at all (console, first
   boot) the switch is direct. Sequence: label and open the new port → write the drop-in →
   `sshd -t` → apply now (flush handlers) → assert sshd itself listens → only then close the
   old port. Any failure stops with the old port still working. (Detect sessions from socket
   state; `sudo` resets the environment, so `SSH_CONNECTION` is not visible.)
2. **Identity cutovers take three steps:** declare the SSO administrators → sign in through SSO
   and perform a privileged action (seeing the UI is not enough) → only then disable the local
   admin. Keep a documented break-glass path that does not depend on the SSO chain.
3. **Refuse self-harm:** never revoke yourself; never remove the last administrator; a
   console-only account list must not intersect the operators list.
4. **No declarative full replacement where a missing line locks someone out.** `authorized_keys`
   is append-only during convergence; removal is an explicit command.
5. **Preview/confirm pairs for destructive operations:** `<op>` prints exactly what would happen
   and changes nothing; `<op>-confirm` does it. Destructive tools read the same variables as
   convergence — a hardcoded path in a purge tool deletes stale paths and reports success.
6. **Protect lists, not delete lists, for resets:** "wipe all application data except what is
   explicitly protected". New things are reset by default; forgetting costs rebuilding
   reproducible data, never leaving orphaned state nobody will notice.
7. **Automate only what cannot destroy existing data.** Creating a logical volume from free
   space and formatting it is automated. Partitioning or formatting a whole disk is a one-time
   manual script that identifies the disk by WWN and serial (device names change between boots),
   refuses system and mounted devices, and makes the operator type the serial.
8. **Never write into an empty mountpoint:** services whose data lives on a mount declare
   `RequiresMountsFor=`; data paths are fixed rather than configurable (a configurable path is a
   daily chance to put data where there is no monitoring and no backup).
9. **Revoking access and deleting data are different commands:** the first must be possible
   immediately, the second may wait.

## Consequences

- Mistakes stop in a recoverable state.
- Accepted cost: more targets, two-step flows, and some changes that need a second run.
- Accepted cost: transitional states (sshd on two ports) exist for a while and are announced in
  the run output.

## Alternatives considered

- **Single-shot idempotent changes:** deadlock (two services each holding the port the other
  wants) or lock-out when the operator sits on the path being changed.
- **Runbooks that say "be careful":** not enforced, not remembered.

## Revisit when

This is a principle, not a choice to revisit. Individual guards can relax when every host has
reliable out-of-band access (serial console, IPMI) that makes a lock-out cheap to recover.
