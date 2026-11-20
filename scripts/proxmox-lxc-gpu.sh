#!/usr/bin/env bash
#
# Configure an unprivileged Proxmox LXC for NVIDIA CUDA + Docker:
#   - Proxmox features required by Docker-in-LXC
#   - NVIDIA LXC hook (user-space driver injection)
#   - cgroup v2 device rules for the NVIDIA majors (detected dynamically)
#   - 16 GiB /dev/shm
#   - optional read-only bind mount of the airgap bundle at /airgap-bundle
#
# Run this on the Proxmox host as root, after the LXC exists:
#   ./proxmox-lxc-gpu.sh 120
#   ./proxmox-lxc-gpu.sh 120 --bundle /srv/airgap-bundle
#
# The host must already have the NVIDIA driver and nvidia-container-toolkit
# installed (see docs/HOST-INSTALL.md). The LXC itself stays unprivileged.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: proxmox-lxc-gpu.sh <CTID> [--bundle DIR]

  CTID          Proxmox container ID (e.g. 120)
  --bundle DIR  Optional airgap bundle directory, mounted read-only at
                /airgap-bundle inside the LXC.

Must be run as root on the Proxmox host.
EOF
}

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: must run as root on the Proxmox host" >&2
  exit 1
fi

CTID=""
BUNDLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    *[!0-9]*) echo "ERROR: invalid CTID '$1'" >&2; usage; exit 1 ;;
    *) CTID="$1"; shift ;;
  esac
done

if [[ -z "$CTID" ]]; then
  usage
  exit 1
fi

CONF="/etc/pve/lxc/${CTID}.conf"
if [[ ! -f "$CONF" ]]; then
  echo "ERROR: $CONF not found (does CT ${CTID} exist?)" >&2
  exit 1
fi

if ! command -v pct >/dev/null; then
  echo "ERROR: pct not found; this script must run on a Proxmox VE host" >&2
  exit 1
fi

if ! command -v nvidia-smi >/dev/null; then
  echo "ERROR: nvidia-smi not found; install the NVIDIA driver first (docs/HOST-INSTALL.md)" >&2
  exit 1
fi

if ! command -v nvidia-container-cli >/dev/null; then
  echo "ERROR: nvidia-container-cli not found; install nvidia-container-toolkit first (docs/HOST-INSTALL.md)" >&2
  exit 1
fi

if [[ ! -x /usr/share/lxc/hooks/nvidia ]]; then
  echo "ERROR: /usr/share/lxc/hooks/nvidia is missing (lxc-pve too old?)" >&2
  exit 1
fi

if [[ ! -x /usr/bin/nvidia-modprobe ]]; then
  echo "ERROR: /usr/bin/nvidia-modprobe is missing; reinstall the NVIDIA driver" >&2
  exit 1
fi

# Add a line once, preserving any existing unrelated configuration.
add_line() {
  local line="$1"
  grep -Fqx -- "$line" "$CONF" || echo "$line" >> "$CONF"
}

# stat -c %t prints the major in hexadecimal; convert it to decimal.
device_major() {
  local path="$1" hex
  hex=$(stat -c '%t' "$path" 2>/dev/null || true)
  [[ -n "$hex" ]] || return 1
  printf '%d' "0x${hex}"
}

# Proxmox only allows root@pam to change the non-nesting feature flags.
echo "==> Stopping CT ${CTID}"
pct stop "$CTID" >/dev/null 2>&1 || true

echo "==> Enabling Docker-in-LXC features"
pct set "$CTID" --features nesting=1,keyctl=1,fuse=1,mknod=1

# NVIDIA device majors. 195 = nvidia0/nvidiactl/modeset, 509 = uvm, 511 = caps.
declare -A MAJORS=()
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
  if [[ -e "$dev" ]]; then
    major=$(device_major "$dev")
    MAJORS["$major"]=1
  fi
done
# /dev/nvidia-caps is a directory on recent drivers. stat -c %t on the
# directory returns 0, so iterate over the actual caps char devices instead.
if [[ -d /dev/nvidia-caps ]]; then
  for dev in /dev/nvidia-caps/nvidia-cap*; do
    [[ -e "$dev" ]] || continue
    major=$(device_major "$dev")
    MAJORS["$major"]=1
  done
  # Some kernels expose the caps major even if the nodes are created lazily.
  [[ ${#MAJORS[@]} -gt 0 ]] && MAJORS[511]=1
fi

if [[ ${#MAJORS[@]} -eq 0 ]]; then
  echo "ERROR: no NVIDIA device found on the host; is the driver loaded?" >&2
  exit 1
fi

echo "==> Adding cgroup v2 device rules: ${!MAJORS[*]}"
for major in "${!MAJORS[@]}"; do
  add_line "lxc.cgroup2.devices.allow: c ${major}:* rwm"
done

echo "==> Adding the NVIDIA LXC hook and environment"
# Remove the old pre-start line, which exited 1 when /dev/nvidia0 already
# existed and therefore made every LXC start fail. The replacement always
# exits 0.
OLD_PRE_START="lxc.hook.pre-start: sh -c '[ ! -f /dev/nvidia0 ] && /usr/bin/nvidia-modprobe -c0 -u'"
if grep -Fqx -- "$OLD_PRE_START" "$CONF"; then
  awk -v old="$OLD_PRE_START" '$0 != old' "$CONF" > "${CONF}.tmp"
  cat "${CONF}.tmp" > "$CONF"
  rm -f "${CONF}.tmp"
fi
add_line "lxc.hook.pre-start: sh -c 'if [ ! -f /dev/nvidia0 ]; then /usr/bin/nvidia-modprobe -c0 -u; fi'"
add_line "lxc.environment: NVIDIA_VISIBLE_DEVICES=all"
add_line "lxc.environment: NVIDIA_DRIVER_CAPABILITIES=compute,utility"
add_line "lxc.hook.mount: /usr/share/lxc/hooks/nvidia"

echo "==> Adding 16 GiB /dev/shm"
add_line "lxc.mount.entry: tmpfs dev/shm tmpfs size=16G,nosuid,nodev,noexec,create=dir 0 0"

if [[ -n "$BUNDLE" ]]; then
  BUNDLE=$(readlink -f "$BUNDLE")
  if [[ ! -d "$BUNDLE" ]]; then
    echo "ERROR: bundle directory not found: $BUNDLE" >&2
    exit 1
  fi
  existing_mp=$(grep -E '^mp[0-9]+:' "$CONF" | head -1 || true)
  if grep -Fq "mp=/airgap-bundle" "$CONF"; then
    if ! grep -Eq "mp=/airgap-bundle,.*backup=0" "$CONF"; then
      sed -i '/mp=.*mp=\/airgap-bundle/ s/$/,backup=0/' "$CONF"
      echo "==> Added backup=0 to the existing bundle mount"
    fi
    echo "==> Bundle mount already present"
  else
    if [[ -n "$existing_mp" ]]; then
      idx=$(( $(echo "$existing_mp" | sed -E 's/^mp([0-9]+):.*/\1/') + 1 ))
    else
      idx=0
    fi
    add_line "mp${idx}: ${BUNDLE},mp=/airgap-bundle,ro=1,backup=0"
    echo "==> Mounted bundle at mp${idx} -> /airgap-bundle (backup=0)"
  fi
fi

echo "==> Starting CT ${CTID}"
pct start "$CTID"
sleep 3

echo "==> Verifying nvidia-smi inside the LXC"
if ! pct exec "$CTID" -- nvidia-smi -L; then
  echo "ERROR: nvidia-smi failed inside the LXC. See the CT start log:" >&2
  echo "  journalctl -u pve-container@${CTID} -n 100 --no-pager" >&2
  exit 1
fi

echo
echo "OK: CT ${CTID} sees the NVIDIA GPU."
echo "Next: install Docker + nvidia-container-toolkit inside the LXC"
echo "      (ansible-playbook playbook.yml, role lxc_docker), or manually:"
echo "  pct exec ${CTID} -- bash -lc 'nvidia-ctk config --in-place --set nvidia-container-cli.no-cgroups=true'"
echo "  pct exec ${CTID} -- bash -lc 'nvidia-ctk runtime configure --runtime=docker && systemctl restart docker'"
