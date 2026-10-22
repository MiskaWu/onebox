# storage — mounts and logical volumes

Mounts the host's data disks as systemd `.mount` units and, optionally, carves LVM logical
volumes out of an existing volume group. Typical use: a volume of its own for GitLab's hot
data (`/srv/gitlab`), for the CI runner's home (`/var/lib/gitlab-runner`), and a separate
disk for backups.

```yaml
# inventories/<env>/group_vars/onebox/main.yml
onebox_components: [storage, …]
storage_lvs:
  - {vg: vg0, name: gitlab, size: 100G, fs: xfs, where: /srv/gitlab, mode: "0700"}
  - {vg: vg0, name: runner, size: 80G, fs: xfs, where: /var/lib/gitlab-runner}
storage_mounts:
  - {what: UUID=0f1e2d3c-…, where: /srv/backup, type: xfs, mode: "0700"}
```

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `storage_mounts` | `[]` | `{what, where, type, options, owner, group, mode}` — see `defaults/main.yml` |
| `storage_lvs` | `[]` | `{vg, name, size, fs, where, options, owner, group, mode}` |
| `storage_mount_options_default` | `defaults,nofail,noatime` | options when an entry has none |

`what` takes `UUID=`, `PARTUUID=`, `LABEL=`, a `/dev/…` path or `host:/export` (NFS). The
`UUID=`-style forms are turned into `/dev/disk/by-*` paths in `What=`, because systemd only
ties a mount to its device unit (and waits for the device) when `What=` is a device path.

## Contracts

- **Other roles depend on mounts by path.** `gitlab` and `gitlab_runner` put
  `RequiresMountsFor=<path>` in their units and can refuse to converge while the path is not
  a mount point (`gitlab_required_mounts`, `gitlab_runner_home_must_be_mount`). Run
  `make storage` before them on a new host.
- One unit per mount in `/etc/systemd/system/<escaped path>.mount`. The role refuses to run
  while `/etc/fstab` also lists one of its mount points — two definitions of one mount drift
  apart, and `mount -a` or the next person reading fstab only sees one of them.
- Removing an entry does **not** unmount anything or delete its unit: unmounting a file
  system is a decision for a human (`systemctl disable --now <unit>.mount`, then delete the file).

## Why it is built like this

**Where the line for automation is drawn.** The question is never "does this run mkfs", it is
"can a mistake destroy data that already exists":

- Disks and partitions in `storage_mounts` are never formatted. Device names like `/dev/sdb`
  change between boots, and an unattended run that formats "the second disk" can format the
  wrong one. Prepare them by hand once (partition, `mkfs`, `blkid` for the UUID).
- Logical volumes are carved only from *free* extents, so creating one cannot touch existing
  data. A file system is created only when the entry asks for it (`fs:`) **and** `blkid -p`
  finds no signature of any kind on the volume, and never with a force flag. An existing
  volume with data is left alone, and one with a different file system is reported.
- Volume groups and physical volumes are not managed: they are whole-disk decisions.

**`nofail` everywhere by default.** A broken data disk should not keep the host from booting
(you still need SSH to fix it). `nofail` makes the mount wanted, not required, by the boot
target. The other half of the bargain is in the services: `RequiresMountsFor=` keeps them
down while their mount is missing, so GitLab never initialises a fresh, empty instance in the
directory underneath a failed mount (the "split-brain" that is far worse than an outage).
A missing disk delays boot by the device timeout (90 s by default). Leave `nofail` out of an
entry's `options` only for a disk the host must not run without.

**Unit names.** A mount unit must be named after its path (`/srv/gitlab-runner` →
`srv-gitlab\x2drunner.mount`). The role derives the name itself, which is exact for the
characters preflight allows in mount points (`[A-Za-z0-9_.-]` components).

## Operations

```bash
sudo make storage                       # create LVs, write units, mount
findmnt /srv/gitlab                     # what is mounted where
systemctl status srv-gitlab.mount       # one mount's state and errors
```

**Growing a logical volume** (online, no downtime, xfs and ext4):

```bash
sudo lvextend --resizefs --size +50G /dev/vg0/gitlab
```

Growing is a deliberate act and not a converge: xfs can never shrink, so a typo in an
inventory size would be permanent. After growing, update `size` in the inventory to the new
value so it documents reality (the role reads it only when creating the volume).
Suggested target: `make storage-grow LV=vg0/gitlab SIZE=+50G`.

**Changing options**: edit `options` and converge — the unit is reloaded, which for a mount
means a remount with the new options. Changing `what` or `type` needs an unmount:
stop the services using it, `systemctl stop <unit>.mount`, converge.

**Moving data onto a new volume** (e.g. GitLab, which ran on the root file system before):
add the LV *with a temporary `where`* (e.g. `/mnt/gitlab-new`), converge, stop the service,
`cp -a /srv/gitlab/. /mnt/gitlab-new/`, move the old directory aside, change `where` to the
real path, converge, start the service, check it, then delete the old copy.

## Pitfalls

- **SELinux labels of a new file system** start as `unlabeled_t`/`default_t`. Containers
  relabel their own volumes (`:Z`); for anything else run `restorecon -R <mount point>` or pass
  a `context=` mount option.
- **`noexec`** breaks anything that executes from the mount — notably rootless podman in the
  runner's home (gitlab_runner asserts it).
- **NFS**: the client package (`nfs-utils` / `nfs-common`) is installed for you; the unit
  waits for `network-online.target` and hangs off `remote-fs.target`.
