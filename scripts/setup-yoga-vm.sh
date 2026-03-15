#!/bin/bash
# Build a rootfs disk image for the yoga-app and create a Flint snapshot.
# Requires: sudo (for mount), bun, flint built at ../zig-out/bin/flint
#
# Usage: sudo ./scripts/setup-yoga-vm.sh
# Output: /tmp/flint-yoga/ with vmstate, mem, and disk files

set -euo pipefail

FLINT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YOGA_DIR="$FLINT_DIR/../yoga-app"
WORK="/tmp/flint-yoga"
DISK="$WORK/rootfs.img"
MNT="$WORK/mnt"
KERNEL="/tmp/vmlinuz-flint"
FLINT="$FLINT_DIR/zig-out/bin/flint"
AGENT="$FLINT_DIR/zig-out/bin/flint-agent"
DISK_SIZE_MB=2048

echo "=== Flint Yoga VM Setup ==="

# Preflight checks
for f in "$KERNEL" "$FLINT" "$AGENT"; do
    [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done
[ -d "$YOGA_DIR" ] || { echo "missing: $YOGA_DIR"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# Get the real user for ownership fixup later
REAL_USER="${SUDO_USER:-$(whoami)}"

mkdir -p "$WORK" "$MNT"

# 1. Create sparse disk image
echo "--- Creating ${DISK_SIZE_MB}MB disk image ---"
dd if=/dev/zero of="$DISK" bs=1M count=0 seek=$DISK_SIZE_MB 2>/dev/null
mkfs.ext4 -q -F "$DISK"

# 2. Mount and populate rootfs
echo "--- Populating rootfs ---"
mount -o loop "$DISK" "$MNT"
trap "umount '$MNT' 2>/dev/null; exit" EXIT

# Minimal directory structure
mkdir -p "$MNT"/{bin,sbin,dev,proc,sys,tmp,etc,var/log,root,app}

# Download static busybox (Alpine)
if [ ! -f /tmp/busybox-static ]; then
    echo "--- Downloading busybox ---"
    curl -sL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        -o /tmp/busybox-static
    chmod +x /tmp/busybox-static
fi
cp /tmp/busybox-static "$MNT/bin/busybox"

# Install busybox symlinks
chroot "$MNT" /bin/busybox --install -s /bin 2>/dev/null || true
ln -sf /bin/busybox "$MNT/sbin/init" 2>/dev/null || true
ln -sf /bin/busybox "$MNT/sbin/reboot" 2>/dev/null || true

# Install Bun
echo "--- Installing Bun ---"
BUN_PATH="$(which bun 2>/dev/null || echo /usr/bin/bun)"
if [ -f "$BUN_PATH" ]; then
    cp "$BUN_PATH" "$MNT/bin/bun"
else
    echo "bun not found, skipping"
fi

# Install flint-agent
cp "$AGENT" "$MNT/bin/flint-agent"

# Copy yoga app
echo "--- Copying yoga app ---"
rsync -a --exclude='.git' --exclude='frontend' "$YOGA_DIR/" "$MNT/app/"

# Create env file template (user must fill in secrets)
if [ ! -f "$YOGA_DIR/backend/.env" ]; then
    cat > "$MNT/app/backend/.env" << 'ENVEOF'
# Fill in your keys:
# CLERK_SECRET_KEY=sk_test_...
# CLERK_PUBLISHABLE_KEY=pk_test_...
# GEMINI_API_KEY=...
DB_FILE_NAME=./yoga.db
NODE_ENV=production
ENVEOF
    echo "WARNING: No backend/.env found. Created template at $MNT/app/backend/.env"
    echo "         Edit $DISK (mount and update) or use sandbox/write to inject secrets."
else
    cp "$YOGA_DIR/backend/.env" "$MNT/app/backend/.env"
fi

# Init script: starts networking, bun app, and flint-agent
cat > "$MNT/sbin/init" << 'INITEOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /tmp
mkdir -p /dev/pts
mount -t devpts none /dev/pts

# Hostname
hostname flint-yoga

# Network (configured by TAP on host side)
ip link set lo up
ip link set eth0 up 2>/dev/null
ip addr add 172.16.0.2/24 dev eth0 2>/dev/null
ip route add default via 172.16.0.1 2>/dev/null

# DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Start flint-agent in background (vsock communication with host)
/bin/flint-agent &

# Start the yoga app backend
cd /app/backend
echo "Starting yoga-app backend..."
/bin/bun src/index.ts > /var/log/app.log 2>&1 &

# Keep init alive
while true; do sleep 3600; done
INITEOF
chmod +x "$MNT/sbin/init"

# Ensure /etc/passwd exists (some tools need it)
cat > "$MNT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "$MNT/etc/group" << 'EOF'
root:x:0:
EOF

echo "--- Rootfs size ---"
du -sh "$MNT"

umount "$MNT"
trap - EXIT

# Fix ownership so non-root user can use the files
chown "$REAL_USER:$REAL_USER" "$DISK"

echo ""
echo "=== Disk image ready: $DISK ==="
echo ""
echo "Next steps:"
echo "  1. If you need to add .env secrets:"
echo "     sudo mount -o loop $DISK $MNT"
echo "     sudo vi $MNT/app/backend/.env"
echo "     sudo umount $MNT"
echo ""
echo "  2. Create a snapshot (boots VM, pauses, saves state):"
echo "     $FLINT $KERNEL --disk $DISK --vsock-cid 3 --vsock-uds /tmp/flint-yoga-vsock \\"
echo "       --api-sock /tmp/flint-yoga-api.sock \\"
echo "       'console=ttyS0 nokaslr reboot=k panic=1 pci=off root=/dev/vda rw'"
echo ""
echo "  3. Then from another terminal:"
echo "     # Wait for boot (~1s), then pause + snapshot:"
echo "     curl -X PATCH --unix-socket /tmp/flint-yoga-api.sock http://localhost/vm -d '{\"state\":\"Paused\"}'"
echo "     curl -X PUT --unix-socket /tmp/flint-yoga-api.sock http://localhost/snapshot/create \\"
echo "       -d '{\"snapshot_path\":\"$WORK/snap.vmstate\",\"mem_file_path\":\"$WORK/snap.mem\"}'"
echo ""
echo "  4. Start the pool:"
echo "     $FLINT pool --vmstate-path $WORK/snap.vmstate --mem-path $WORK/snap.mem \\"
echo "       --disk $DISK --vsock-cid 3 --vsock-uds /tmp/flint-yoga-vsock \\"
echo "       --ready-cmd 'curl -sf http://localhost:3000/api/health' \\"
echo "       --pool-size 2 --pool-sock /tmp/flint-yoga-pool.sock"
