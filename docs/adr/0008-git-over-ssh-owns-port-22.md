# 0008. git-over-SSH owns port 22; the admin sshd moves

- Status: Accepted
- Related: [0007](0007-host-firewall-scope.md), [0009](0009-guarded-irreversible-changes.md), [0012](0012-datastore-reachability.md)

## Context

Everyone uses `git clone git@gitlab.example.com:group/repo.git` daily, and networks often allow
outbound 22 but not arbitrary ports. The host has one address; both the host's sshd and the
forge's SSH server want port 22. SSH has no SNI: the client sends its banner without naming the
target host, so no L4 or L7 proxy can split one `IP:22` between two SSH servers.

## Decision

- **Port 22 belongs to the forge's git-over-SSH** (a container published port). The host's admin
  sshd moves to `common_admin_ssh_port` (for example 2222).
- The SSH port the forge advertises in clone URLs and the port it publishes derive from one
  variable, so they cannot diverge.
- **Order matters:** the `common` play moves sshd before the forge play claims 22. On a running
  host the move follows the lock-out-safe procedure of
  [0009](0009-guarded-irreversible-changes.md).
- Before moving, assert the target port is free or already sshd's: a container holding it would
  make "is sshd listening on the new port?" pass for the wrong process.
- On SELinux hosts the new port gets the `ssh_port_t` label before sshd binds it
  (`policycoreutils-python-utils` provides `semanage` and is part of the base packages).
- Once nobody is connected on the old port, the firewalld `ssh` service is removed. It is
  meaningless anyway for a DNAT'd port 22 ([0007](0007-host-firewall-scope.md)).

## Consequences

- Clean clone URLs for everyone, every day.
- Accepted cost: operators use `ssh -p 2222` (one `~/.ssh/config` entry). Connecting to 22 lands
  in the forge's git shell and answers "Permission denied (publickey)" — not a broken key, the
  wrong service. SSH tunnels on 22 fail the same way because the git shell does not forward.
  Document this where operators look first.
- Port 22 is the scanners' favourite. The forge's SSH accepts keys only.
- git-over-SSH is DNAT'd, so firewalld cannot restrict its sources.

## Alternatives considered

- **Leave sshd on 22 and publish git on another port:** zero host change, but networks that
  only allow 22 break git, and every clone URL carries a port.
- **A second IP address, both services on 22:** the cleanest result, but it needs an address
  and routing that the platform may not control.
- **HTTPS clones with tokens only:** the answer when only 443 is allowed, not a reason to give up
  SSH where it works.
- **An SSH-aware multiplexer:** impossible without SNI.

## Revisit when

- A second address is available: give each service its own 22.
- The network allows only 443: that is a different problem (HTTPS clone, SSH over 443), not
  another port shuffle.
