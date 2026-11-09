# DockedFS

**Swap spare disk space with friends for encrypted offsite backups. Docker and Tailscale handle the setup, so nobody has to open ports or trust anyone with their data.**

DockedFS is not a new program. It ties together mature, well-understood tools (iSCSI, Tailscale, LUKS) in a single `docker-compose.yml`. The result is easy for a non-expert to run and easy for anyone to audit.

- **The host** (the friend with spare disk) runs two containers. One gives them a single locked-down device on the client's tailnet. The other serves a disk image over iSCSI.
- **The client** (the friend who needs backup space) connects to it as a raw block device. They encrypt it with LUKS, put any filesystem on it, and mount it like a local drive.

```
 client machine                          host machine (your friend)
 ┌──────────────────────────┐            ┌─────────────────────────────────┐
 │ /mnt/backup  (xfs, ext4…)│            │ dockedfs-tailscale  (userspace) │
 │      │                   │  tailnet   │        │                        │
 │ LUKS2 (keys stay here)   │◀──────────▶│ dockedfs-target (tgt)           │
 │      │                   │  WireGuard │        │                        │
 │ iSCSI initiator          │            │ DATA_DIR/disk.img (ciphertext)  │
 └──────────────────────────┘            └─────────────────────────────────┘
```

## Why

**For the host**
- Your only cost is the disk space and bandwidth you choose to give. You set the limits in a single `.env` file.
- You don't open any ports and you don't change your router.
- Your LAN stays private. The Tailscale container runs in userspace mode, has no access to the host's network devices, and advertises no routes. Your friend's tailnet can reach that one container, on that one port, and nothing else.
- You only ever store ciphertext. The encryption keys never leave your friend's machine, so you can't read the data and neither can anyone who gets at your disk.

**For the client**
- You control the keys.
- You get a real block device, so you can use any filesystem and any backup tool: rsync, restic, Borg, Duplicati, or a plain `cp`.
- It works from anywhere, with no port forwarding on either side.

## Host setup (the friend offering space)

You need Docker with the Compose plugin. Any Linux box, NAS or always-on PC with spare disk will do.

1. Get a **Tailscale auth key** from your friend (see [Client setup](#client-setup), step 1). It's the only thing you need from them, and it's single-use.
2. Clone the repo and create your config:
   ```sh
   git clone https://github.com/chembal/DockedFS.git
   cd DockedFS
   cp .env.example .env
   ```
3. Edit `.env`:

   | Setting | What it does |
   |---|---|
   | `TS_AUTHKEY` | Auth key from your friend. It joins this host to *their* tailnet. |
   | `CHAP_USER`, `CHAP_PASSWORD` | Optional, and empty by default. Set both only if your friend asks for an extra iSCSI login (password must be 12 to 16 characters). |
   | `DATA_DIR` | Folder on this machine where the disk image lives. |
   | `STORAGE_SIZE` | Maximum size offered, e.g. `500G` or `2T`. You can raise it later, but never lower it (see below). |
   | `PREALLOCATE` | `false` grows the file as your friend writes to it. `true` reserves the full size up front. |
   | `MAX_BANDWIDTH_MBIT` | Optional cap in Mbit/s, applied separately to upload and download. Leave it empty for no cap. |

4. Start it:
   ```sh
   docker compose up -d --build
   docker compose logs -f target   # wait for "[dockedfs] Ready"
   ```
5. Tell your friend the host's name on their tailnet (`TS_HOSTNAME`, default `dockedfs`).

**Changing limits.** Edit `.env`, then run `docker compose up -d`. To grow the disk, raise `STORAGE_SIZE`, then have your friend resize on their side (see [Growing the disk](#growing-the-disk)). DockedFS **refuses to start if you lower `STORAGE_SIZE`**, because shrinking the image would destroy your friend's data.

**Stopping for good.** Tell your friend first. Then run `docker compose down` and delete `DATA_DIR/disk.img`.

## Client setup

These steps assume Debian or Ubuntu. Other distros use the same tools under the same names.

### 1. Prepare your tailnet

In the [Tailscale admin console](https://login.tailscale.com/admin/acls), add a tag for the host and limit it to iSCSI only. Remove the default "allow all" rule if your policy still has it. This rule is what controls who can attach the disk, so name only your own login in `src`, not other people who share your tailnet.

```jsonc
{
  "tagOwners": {
    "tag:dockedfs": ["autogroup:admin"]
  },
  "grants": [
    // Only your own devices may reach the DockedFS host, and only on the iSCSI port.
    { "src": ["you@example.com"], "dst": ["tag:dockedfs"], "ip": ["tcp:3260"] }
    // There is no rule *from* tag:dockedfs, so the host can't reach any of your devices.
  ]
}
```

Then [generate an auth key](https://login.tailscale.com/admin/settings/keys) that is **reusable: off, pre-approved: on, tags: `tag:dockedfs`**. Send it to your friend privately, not in a group chat or anywhere public. Once their host has joined, the key is spent.

> **The tag matters.** A key without a tag joins the host as *your* device. Under the default "allow all" policy, your friend's machine could then reach every device on your tailnet. Once the host is up, `tailscale status` should list it as `tagged-devices`, not under your login.

### 2. Connect

**The quick way:** the helper script runs steps 2 to 4 for you.

```sh
sudo mkdir -p /etc/dockedfs
echo 'DOCKEDFS_HOST=dockedfs' | sudo tee /etc/dockedfs/client.conf   # add CHAP_USER/CHAP_PASSWORD only if the host enabled CHAP

sudo ./client/dockedfs-client.sh init     # first time only: LUKS-format, mkfs, mount
sudo ./client/dockedfs-client.sh mount    # later: connect, unlock, mount
sudo ./client/dockedfs-client.sh umount   # unmount, lock, disconnect
sudo ./client/dockedfs-client.sh status
```

**The manual way:**

```sh
sudo apt-get update && sudo apt-get install -y open-iscsi cryptsetup xfsprogs

HOST=$(tailscale ip -4 dockedfs)        # the host's tailnet IP
IQN=iqn.2026-11.io.dockedfs:storage

sudo iscsiadm -m node -o new -T "$IQN" -p "$HOST:3260"
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" --login

DISK=/dev/disk/by-path/ip-$HOST:3260-iscsi-$IQN-lun-1
lsblk "$DISK"
```

If the host enabled CHAP, run these before `--login`:
```sh
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.authmethod -v CHAP
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.username -v "$CHAP_USER"
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.password -v "$CHAP_PASSWORD"
```

> The target is added by its tailnet IP instead of through `sendtargets` discovery. Because the host runs Tailscale in userspace mode, discovery reports a container-internal address that you can't reach.

Use the stable `/dev/disk/by-path/...` name, not `/dev/sdX`. `sdX` names can change, and formatting the wrong one destroys a local disk.

### 3. Encrypt, format and mount (first time only)

```sh
sudo cryptsetup luksFormat --type luks2 --sector-size 4096 "$DISK"
sudo cryptsetup open "$DISK" dockedfs
sudo mkfs.xfs /dev/mapper/dockedfs
sudo mkdir -p /mnt/dockedfs
sudo mount /dev/mapper/dockedfs /mnt/dockedfs
```

**Back up your LUKS header and passphrase somewhere other than this disk.** If you lose them, the data is gone:
```sh
sudo cryptsetup luksHeaderBackup "$DISK" --header-backup-file dockedfs-luks-header.img
```

### 4. Reconnect later

```sh
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" --login
sudo cryptsetup open "$DISK" dockedfs
sudo mount /dev/mapper/dockedfs /mnt/dockedfs
```

To disconnect, run `sudo umount /mnt/dockedfs && sudo cryptsetup close dockedfs && sudo iscsiadm -m node -T "$IQN" --logout`.

### 5. Back up to it

Anything that writes to a directory works:

- **rsync**: `rsync -aHAX --delete ~/ /mnt/dockedfs/home-backup/`
- **restic / Borg**: point the repository at `/mnt/dockedfs/repo` to get deduplication and snapshots.
- **Duplicati**: use `/mnt/dockedfs` as a local-folder destination. Duplicati adds its own bandwidth limiting and scheduling.
- **Share it on your LAN**: export `/mnt/dockedfs` over Samba or NFS, so other machines on your network can back up there too.

### Growing the disk

Once your friend has raised `STORAGE_SIZE` and restarted:
```sh
sudo iscsiadm -m session --rescan
sudo cryptsetup resize dockedfs
sudo xfs_growfs /mnt/dockedfs
```

## Security model

| Threat | Protected? |
|---|---|
| Host (or anyone with the host's disk) reads your files | **Yes.** They only ever see LUKS2 ciphertext, and the keys never leave the client. |
| Someone steals the host's hardware, including `.env` | **Nothing useful.** By default no shared secret is stored there. The Tailscale key is single-use and already spent. The node's identity is tagged and can only receive iSCSI connections, and you can revoke it in one click from your admin console. |
| Client reaches the host's LAN or other devices | **Yes.** Userspace Tailscale with no routes. The only thing reachable is the target container on port 3260. |
| A bug in the iSCSI server is exploited to break into the container | **Partly.** The containers are unprivileged apart from `NET_ADMIN`, but like any container they have normal outbound network access, including to the host's LAN. Keep the image updated. |
| Host reaches your other tailnet devices | **Yes**, if you apply the ACL above. |
| Other people's devices on your tailnet attach the disk | **Yes**, if the ACL `src` lists only you. If you can't narrow it, enable CHAP as a second layer. Even a device that attaches the disk only gets ciphertext, but it could overwrite it. |
| Host deletes or withholds your data | **No.** It's their disk. Treat DockedFS as one copy in a 3-2-1 backup strategy, not as the only one. |
| Host tampers with ciphertext | **Detected only partly.** Plain LUKS2 provides confidentiality, not integrity. Use a backup tool that verifies its data (restic, Borg), or add `--integrity hmac-sha256` to `luksFormat` (slower). |
| Host learns metadata | The host can see how much is stored and when it's written, but not what it is. |

DockedFS makes it technically impossible for the host to read your data. It is not legal advice. Hosts and clients are each responsible for what they store and where.

## Troubleshooting

- **`[dockedfs] ERROR: STORAGE_SIZE ... smaller than the existing disk`**: set `STORAGE_SIZE` back to at least the current size.
- **Login fails with "Authentication failure"**: the host has CHAP enabled, and your `iscsiadm` settings don't match its `.env`, or are missing.
- **Writes hang when the internet drops**: iSCSI queues I/O for `node.session.timeo.replacement_timeout` seconds (default 120) before failing. For long backups over flaky links, raise this value, and use a backup tool that can resume.

## Testing

`./tests/smoke.sh` starts a throwaway target on localhost. It checks that a sparse disk is created, that CHAP (when enabled) rejects bad logins, that the default no-CHAP mode works, that data reads back correctly and survives a restart, and that shrinking is refused. Run it with `sudo -E` (with `open-iscsi` installed) to also test the real client path: LUKS2, xfs, mount, a check that the host only sees ciphertext, remount, and growing the disk while it's online. CI runs the full version on every push.

## License

[MIT](LICENSE)
