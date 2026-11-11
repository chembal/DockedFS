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
 │ LUKS2 (keys stay here)   │◀─────────▶│ dockedfs-target (tgt)           │
 │      │                   │  WireGuard │        │                        │
 │ iSCSI initiator          │            │ DATA_DIR/disk.img (ciphertext)  │
 └──────────────────────────┘            └─────────────────────────────────┘
```

## Why

**For the host**
- Your only cost is the disk space and bandwidth you choose to give. You set the limits in a single `.env` file.
- You don't open any ports and you don't change your router.
- Your LAN stays private. Tailscale runs in userspace mode and advertises no routes, so your friend's tailnet can reach one port in one container and nothing else. A built-in firewall also stops the containers from reaching your LAN, router, NAS or anything else on private addresses. The only traffic it lets out is what Tailscale itself needs (see [What the host's firewall allows](#what-the-hosts-firewall-allows)).
- You only ever store ciphertext. The encryption keys never leave your friend's machine, so you can't read the data and neither can anyone who gets at your disk.

**For the client**
- You control the keys.
- You get a real block device, so you can use any filesystem and any backup tool: rsync, restic, Borg, Duplicati, or a plain `cp`.
- It works from anywhere, with no port forwarding on either side.

## Host setup (the friend offering space)

You need Docker with the Compose plugin. Any Linux box, NAS or always-on PC with spare disk will do.

1. Get a **Tailscale auth key** from your friend (see [Client setup](#client-setup), step 1). It's the only thing you need from them. Leave it in `.env` after the first start, because the iSCSI login is derived from it.
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
   | `CHAP_USER`, `CHAP_PASSWORD` | Advanced, and empty by default. The iSCSI (CHAP) login is then derived from `TS_AUTHKEY`, so only your friend can attach the disk. Set both only to use an explicit login instead (password must be 12 to 16 characters). |
   | `CHAP_DISABLE` | `true` turns the iSCSI login off, so only the tailnet ACL controls access. Not recommended. |
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

**Updating.** Now and then, run `git pull && docker compose pull --ignore-buildable && docker compose build --pull && docker compose up -d`. That picks up the latest Tailscale image and Ubuntu security fixes for the iSCSI server.

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

Then [generate an auth key](https://login.tailscale.com/admin/settings/keys) that is **reusable: off, pre-approved: on, tags: `tag:dockedfs`**. Send it to your friend privately, not in a group chat or anywhere public. Once their host has joined, the key can't be used to add any other device. **Keep a copy:** the iSCSI login is derived from it, so nobody else on your tailnet can attach or overwrite the disk, and there's no second password to exchange.

> **The tag matters.** A key without a tag joins the host as *your* device. Under the default "allow all" policy, your friend's machine could then reach every device on your tailnet. Once the host is up, `tailscale status` should list it as `tagged-devices`, not under your login.

### 2. Run the setup

On the machine you'll back up from (Debian or Ubuntu with Tailscale connected):

```sh
git clone https://github.com/chembal/DockedFS.git
cd DockedFS/client
./dockedfs-client.sh
```

The script checks where you are and walks you through only what's left:

1. Installs the iSCSI and encryption tools if they're missing.
2. Asks for the **auth key** you gave your friend. The disk's login is derived from it.
3. Lists the `tag:dockedfs` hosts on your tailnet so you can pick your friend's.
4. Connects to it.
5. On a blank disk, it encrypts it with LUKS2. You can either **generate a strong key** stored in a root-only key file (recommended, and needed for mounting at boot) or **type your own passphrase**.
6. Creates a filesystem (xfs by default, or ext4).
7. Asks where to mount it (default `/mnt/dockedfs`) and makes it writable by you.
8. Offers to **mount it at boot**. A systemd service retries until your friend's host is reachable.
9. Shows exactly what to **put in your password manager**: the auth key, the encryption key and the LUKS header backup.

Run it again any time. Finished steps are skipped, and if everything is up it just shows the status. Your settings are kept in `/etc/dockedfs/client.conf`, which only root can read.

Day to day, after setup installs it as `dockedfs-client`:

```sh
sudo dockedfs-client status
sudo dockedfs-client umount    # unmount, lock, disconnect
sudo dockedfs-client mount     # connect, unlock, mount
sudo dockedfs-client grow      # after your friend raises STORAGE_SIZE
```

### 3. Doing it by hand

<details>
<summary>Every command the script runs, if you'd rather see or do it yourself</summary>

```sh
sudo apt-get update && sudo apt-get install -y open-iscsi cryptsetup xfsprogs

HOST=$(tailscale ip -4 dockedfs)        # the host's tailnet IP
IQN=iqn.2026-11.io.dockedfs:storage
AUTHKEY='tskey-auth-...'                 # the key you gave the host
CHAP_PASSWORD=$(printf %s "$AUTHKEY" | sha256sum | cut -c1-16)   # first 16 hex chars of the hash
CHAP_USER=$(printf %s "$AUTHKEY" | sha256sum | cut -c17-32)       # next 16

sudo iscsiadm -m node -o new -T "$IQN" -p "$HOST:3260"
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.authmethod -v CHAP
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.username -v "$CHAP_USER"
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" -o update -n node.session.auth.password -v "$CHAP_PASSWORD"
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" --login

DISK=/dev/disk/by-path/ip-$HOST:3260-iscsi-$IQN-lun-1
lsblk "$DISK"
```

If the host set an explicit `CHAP_USER`/`CHAP_PASSWORD`, use those instead. If it set `CHAP_DISABLE=true`, skip the three `auth` lines.

> The target is added by its tailnet IP instead of through `sendtargets` discovery. Because the host runs Tailscale in userspace mode, discovery reports a container-internal address that you can't reach.

Use the stable `/dev/disk/by-path/...` name, not `/dev/sdX`. `sdX` names can change, and formatting the wrong one destroys a local disk.

**Encrypt, format and mount (first time only)**

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

**Reconnect later**

```sh
sudo iscsiadm -m node -T "$IQN" -p "$HOST:3260" --login
sudo cryptsetup open "$DISK" dockedfs
sudo mount /dev/mapper/dockedfs /mnt/dockedfs
```

To disconnect, run `sudo umount /mnt/dockedfs && sudo cryptsetup close dockedfs && sudo iscsiadm -m node -T "$IQN" --logout`.

</details>

### 4. Back up to it

Anything that writes to a directory works:

- **rsync**: `rsync -aHAX --delete ~/ /mnt/dockedfs/home-backup/`
- **restic / Borg**: point the repository at `/mnt/dockedfs/repo` to get deduplication and snapshots.
- **Duplicati**: use `/mnt/dockedfs` as a local-folder destination. Duplicati adds its own bandwidth limiting and scheduling.
- **Share it on your LAN**: export `/mnt/dockedfs` over Samba or NFS, so other machines on your network can back up there too.

### Growing the disk

Once your friend has raised `STORAGE_SIZE` and restarted, run `sudo dockedfs-client grow`, or by hand:
```sh
sudo iscsiadm -m session --rescan
sudo cryptsetup resize dockedfs
sudo xfs_growfs /mnt/dockedfs
```

## Security model

| Threat | Protected? |
|---|---|
| Host (or anyone with the host's disk) reads your files | **Yes.** They only ever see LUKS2 ciphertext, and the keys never leave the client. |
| Someone steals the host's hardware, including `.env` | **Nothing useful.** The used auth key can't add new devices. The iSCSI login derived from it only unlocks ciphertext they already hold. The node's identity is tagged and can only receive iSCSI connections, and you can revoke it in one click from your admin console. |
| Client reaches the host's LAN or other devices | **Yes.** Userspace Tailscale with no routes, so tailnet traffic can only reach the iSCSI server on loopback. The firewall also blocks every private and link-local address. |
| A bug in the iSCSI server is exploited to break into the container | **Contained.** The server runs as an unprivileged `tgt` user with no network beyond loopback: it can't reach the LAN or the internet. The container's filesystem is read-only, it can't gain privileges, and its only data is the encrypted image. Keep the images updated. |
| Exfiltration of the host's data | **Blocked.** The containers can only see `DATA_DIR`, which holds ciphertext. They can't reach anything on the host's LAN, and only Tailscale's own traffic types can leave. Tailscale's log upload is turned off (`--no-logs-no-support`). |
| Host reaches your other tailnet devices | **Yes**, if you apply the ACL above. |
| Other people's devices on your tailnet attach or overwrite the disk | **Yes.** They'd need the iSCSI login, which is derived from an auth key only you and the host have seen. Narrowing the ACL `src` to your own login adds a second layer. |
| Host deletes or withholds your data | **No.** It's their disk. Treat DockedFS as one copy in a 3-2-1 backup strategy, not as the only one. |
| Host tampers with ciphertext | **Detected only partly.** Plain LUKS2 provides confidentiality, not integrity. Use a backup tool that verifies its data (restic, Borg), or add `--integrity hmac-sha256` to `luksFormat` (slower). |
| Host learns metadata | The host can see how much is stored and when it's written, but not what it is. |

### What the host's firewall allows

Both containers share one network namespace, and `target/firewall.sh` sets it up at start:

| Traffic | Allowed? |
|---|---|
| Anything to a private, link-local, CGNAT or multicast address (your LAN, router, NAS, Docker host, cloud metadata) | **No** |
| Anything at all from the iSCSI server's `tgt` user, other than loopback | **No** |
| Out to the internet: HTTPS and HTTP (Tailscale's control server and DERP relays) and UDP (WireGuard and STUN) | Yes |
| Out to the internet on any other port | **No** |
| In: replies, plus WireGuard UDP from public addresses | Yes |
| In: anything else, including port 3260 from the host or LAN | **No** |

DNS goes to Docker's built-in resolver on loopback. If the Tailscale container restarts, the target container notices and restarts too, so the rules are always in place. `FIREWALL=false` in `.env` turns all this off, which is only meant for debugging.

DockedFS makes it technically impossible for the host to read your data. It is not legal advice. Hosts and clients are each responsible for what they store and where.

## Troubleshooting

- **`[dockedfs] ERROR: STORAGE_SIZE ... smaller than the existing disk`**: set `STORAGE_SIZE` back to at least the current size.
- **Login fails with "Authentication failure"**: the CHAP login doesn't match. Check that `DOCKEDFS_AUTHKEY` is exactly the key in the host's `.env` (`sudo dockedfs-client chap` prints the derived login).
- **Writes hang when the internet drops**: iSCSI queues I/O for `node.session.timeo.replacement_timeout` seconds (default 120) before failing. For long backups over flaky links, raise this value, and use a backup tool that can resume.

## Testing

`./tests/smoke.sh` starts a throwaway target on localhost. It checks that a sparse disk is created, that CHAP rejects bad logins, that the login derived from the auth key works, that `CHAP_DISABLE` works, that data reads back correctly and survives a restart, and that shrinking is refused. Run it with `sudo -E` (with `open-iscsi` installed) to also test the real client path: LUKS2, xfs, mount, a check that the host only sees ciphertext, remount, growing the disk while it's online, and the guided setup end to end. CI runs the full version on every push.

## License

[MIT](LICENSE)
