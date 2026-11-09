** DockerFS **

DockerFS is a simple solution for allowing your friends to use you extra local diskspace and bandwidth as an offsite backup target.

DockerFS is not a new program.  The project uses a collection of mature technologies combined into an easy to use docker-compose.yml file to simplify how you share storage.

The goals of DockerFS:

 - Make it simple for your friend to offer their surplus disk-space and bandwidth without any risk to themselves other than their expended local resources, which they can control and limit.
 - Use tailscale to allow network access between client and server without any special networking configuration by the host server or their network infrastructure
 - Ensure that by offering their resources as a backup target with DockerFS, the host is not opening their local network to the client.
 - Limit legal liability by ensuring that even compelled access by authorities would only show an encrypted block of data that physically cannot be
   accessed, since the encryption keys remain on the client.
 - Ensure that the host can limit maximum resource usage by updating simple parameters in docker-compose.yml
   - Configurable parameters include:
     - Destination data directory
     - Maximum storage amount
     - Grow storage as needed versus pre-allocation
     - Maximum bandwidth utilization
 - Client side advantages
   - You control your keys.  They only exist on your client system.
   - Easy network access via tailscale
   - Ensure the rest of your tailscale network cannot be browsed by using the shared tailscale key via tailscale ACLs
   - File system flexibility.
     - Fundamentally, the server is presenting a block storage device that can be used in any way you'd like.
     - Any filesystem can be used on the client side.  Use whatever best fits your use-case, mount it, and use it.
   - Once mounted, you can use the new mount-point any way you'd like.
     - The primary use-case is for remote backups, but you can use whatever backup technology you prefer.
       - Use rsync, the traditional go-to for file syncronization
       - Use duplicati to take advantage of de-duplication, snapshotting, and bandwidth limiting
       - Simply copy your files to the new mount just like you would any other drive.  Share it over smb if you'd like to allow other systems on your network to backup files there.

Host Server Setup:

 1. Update docker-compose.yml
   - Update data folder mapping
   - Update maximum limits for volume size
   - Update tailscale key (obtain from client party)

 2. Run docker container
   - docker compose up -d

Client Server Setup:

  1. Install tools:
        - sudo apt-get update && sudo apt-get install -y open-iscsi cryptsetup
  2. Discover and connect over Tailscale:
        - sudo iscsiadm -m discovery -t sendtargets -p sudo iscsiadm -m node --login
  3. Identify device: lsblk
  4. Format with LUKS2 (4KB block size):
        - sudo cryptsetup luksFormat --type luks2 --block-size 4096 /dev/sdb
  5. Open volume:
        - sudo cryptsetup open /dev/sdb remote_encrypted_disk
  6. Create filesystem:
        - sudo mkfs.xfs /dev/mapper/remote_encrypted_disk
  7. Mount locally:
        - sudo mkdir -p /mnt/secure_storage
        - sudo mount /dev/mapper/remote_encrypted_disk /mnt/secure_storage
  8. Use the technology of your choice to write backups to /mnt/secure_storage
	- rsync
	- duplicati
	- simply copy files there
  9. (optional) Share the storage on your network via smb/cifs or nfs
	- Include steps here
