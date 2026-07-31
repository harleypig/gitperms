#!/bin/sh
#
# Tier 3 -- the operations that are unsafe to run against a working system:
#
#   * chown to arbitrary uids and gids
#   * device nodes via mknod(1), and the major/minor split in
#     make_special_file
#   * FS_IOC_SETFLAGS, including the immutable and append-only flags that need
#     CAP_LINUX_IMMUTABLE
#   * setuid and setgid preservation across the chown-then-chmod ordering
#   * hardlink reconstruction, which unlinks and relinks real files
#
# SCAFFOLD. The container plumbing below is real and documented; no tier-3
# tests exist yet, so the runner reports SKIP (77) rather than pretending to
# pass.
#
# THE TRAP, recorded so the next increment does not lose a day to it:
# FS_IOC_SETFLAGS is not implemented on overlayfs, which is docker's default
# storage driver. Ext2-attribute tests run against a container's ordinary
# filesystem fail for reasons that have nothing to do with gitperms. Tier 3
# must create a loopback ext4 image *inside* the container and mount it --
# hence --privileged (or CAP_SYS_ADMIN plus /dev/loop-control).
#
# CAP_MKNOD and CAP_CHOWN are both in docker's default capability set, so the
# device-node and chown tests do not need full privilege; only the ext2
# attribute tests do. Keep that split: the weaker half then runs in more
# environments (rootless docker, hardened CI runners) than the ext4 half.
#
# Exit status: 0 pass, 77 skip, anything else fail.

set -u

##############################################################################
# Settings

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../.." && pwd)

SKIP_STATUS=77

IMAGE=${TIER3_IMAGE:-perl:5.42}

# Size of the loopback ext4 image the attribute tests mount.
LOOP_MB=${TIER3_LOOP_MB:-64}

##############################################################################

# The half that needs only docker's default capabilities: root inside the
# container, no --privileged.
run_capable() {

  docker run --rm \
    --volume "$root:/src:ro" \
    "$IMAGE" \
    sh -c 'cp -a /src /tmp/gitperms && cd /tmp/gitperms && prove -I t/lib t/tier3/capable'

}

# The half that needs a real ext4 filesystem. Everything the attribute tests
# touch lives on the loopback mount, never on overlayfs.
run_privileged() {

  docker run --rm --privileged \
    --volume "$root:/src:ro" \
    "$IMAGE" \
    sh -c "
      set -e
      apt-get update -qq && apt-get install -y -qq e2fsprogs >/dev/null
      dd if=/dev/zero of=/tmp/ext4.img bs=1M count=${LOOP_MB} status=none
      mkfs.ext4 -q -F /tmp/ext4.img
      mkdir -p /mnt/ext4
      mount -o loop /tmp/ext4.img /mnt/ext4
      cp -a /src /mnt/ext4/gitperms
      cd /mnt/ext4/gitperms
      prove -I t/lib t/tier3/privileged
    "

}

##############################################################################
# Main

if ! command -v docker >/dev/null 2>&1; then
  echo 'tier 3: docker is not installed'
  exit "$SKIP_STATUS"
fi

if ! docker info >/dev/null 2>&1; then
  echo 'tier 3: docker is installed but not usable'
  exit "$SKIP_STATUS"
fi

if [ ! -e /dev/loop-control ]; then
  echo 'tier 3: no /dev/loop-control, so a loopback ext4 image cannot be mounted'
  exit "$SKIP_STATUS"
fi

echo 'tier 3: no tests implemented yet (scaffold only)'
echo "tier 3: image ${IMAGE}, ${LOOP_MB}MB loopback ext4 for the attribute half"

exit "$SKIP_STATUS"

# Reached once tier 3 is filled in:
# run_capable && run_privileged
