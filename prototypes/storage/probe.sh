#!/bin/sh
printf 'GUEST_KERNEL=%s\n' "$(uname -r)"
printf 'WORKLOAD_UID=%s\n' "$(id -u)"
sed -n '/^CapEff:/p; /^CapBnd:/p' /proc/self/status
df -B1 /bounded
dd if=/dev/zero of=/bounded/probe bs=1048576 count=16 conv=fsync 2>&1
printf 'WRITE_EXIT=%s\n' "$?"
printf 'FILE_BYTES=%s\n' "$(wc -c < /bounded/probe)"
sh -c 'printf unsafe > /tmp/outside'
printf 'ROOT_WRITE_EXIT=%s\n' "$?"
mount -o remount,size=32m /bounded
printf 'REMOUNT_EXIT=%s\n' "$?"
unshare -Ur -m sh -c 'mount -t tmpfs -o size=32m tmpfs /bounded'
printf 'USER_NAMESPACE_MOUNT_EXIT=%s\n' "$?"
printf 'PROBE_COMPLETE\n'
sleep 60
