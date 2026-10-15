#!/bin/bash
# Undo install.sh: remove NVIDIA's 580 driver and repo, then reinstall the previous driver
# from the offline copies saved in $STATE_DIR (or fall back to nouveau if there were none).
# Works without network access.
#
# Usage: sudo ./rollback.sh
set -euo pipefail

STATE_DIR=${STATE_DIR:-/var/backups/nvidia-580-switch}
REPO_LIST=/etc/apt/sources.list.d/nvidia-d12.list
REPO_KEY=/etc/apt/keyrings/nvidia-d12-archive.key
GPGV_CONF=/etc/apt/apt.conf.d/10gpgv
GPGV_LINE='APT::Key::GPGVCommand "/usr/bin/gpgv";'
PIN_FILE=/etc/apt/preferences.d/nvidia-580-no-debian-overrides
MODPROBE_CONF=/etc/modprobe.d/nvidia-580-local.conf
DRIVER_RE='^(nvidia-|libnvidia-|libcuda|libnvcuvid|libnvoptix|libgl1-nvidia|libgles-nvidia|libglx-nvidia|libegl-nvidia|glx-alternative-|xserver-xorg-video-nvidia|firmware-nvidia|libxnvctrl|cuda-drivers)'

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

[[ $EUID -eq 0 ]] || die "run with sudo"
DEBS=()
[[ -d $STATE_DIR/debs ]] && mapfile -t DEBS < <(find "$STATE_DIR/debs" -name '*.deb' | sort)
if [[ ${#DEBS[@]} -gt 0 ]]; then
    echo "Will restore ${#DEBS[@]} saved driver packages from $STATE_DIR/debs"
else
    echo "No saved driver packages in $STATE_DIR/debs: you will end up on the open-source nouveau driver."
fi
read -rp "Roll back now? [y/N] " a; [[ $a == [yY] ]] || exit 1

step "1. Finding packages installed from NVIDIA's repo"
# Exact match on (package, version) against the NVIDIA repo index; fall back to package names.
lists=$(ls /var/lib/apt/lists/*developer.download.nvidia.com*_Packages 2>/dev/null || true)
installed=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version} ${Architecture}\n' | awk '$1 ~ /^[ih]i/ {print $2, $3, $4}')
if [[ -n $lists ]]; then
    mapfile -t NV < <(awk 'FNR==NR { if ($1=="Package:") p=$2; else if ($1=="Version:") have[p" "$2]=1; next }
                          (($1" "$2) in have) {print $1":"$3}' <(cat $lists) <(echo "$installed"))
else
    mapfile -t NV < <(awk '{print $1":"$3}' <<<"$installed" | grep -E "$DRIVER_RE")
fi
# dkms (and other shared tools) must be downgraded, not purged: purging would drop other DKMS modules.
DOWNGRADE=()
PURGE=()
for p in "${NV[@]}"; do
    if [[ ${p%%:*} =~ $DRIVER_RE || ${p%%:*} == nvidia-driver-pinning-* ]]; then PURGE+=("$p"); else DOWNGRADE+=("${p%%:*}"); fi
done
echo "Purging ${#PURGE[@]} NVIDIA packages"; [[ ${#DOWNGRADE[@]} -gt 0 ]] && echo "Reverting to the Debian version: ${DOWNGRADE[*]}"

step "2. Removing NVIDIA 580"
[[ ${#PURGE[@]} -gt 0 ]] && apt-get purge -y "${PURGE[@]}"

step "3. Removing NVIDIA repo and config changes"
rm -f "$REPO_LIST" "$REPO_KEY" "$PIN_FILE" "$MODPROBE_CONF"
[[ -f $GPGV_CONF && $(cat "$GPGV_CONF") == "$GPGV_LINE" ]] && rm -f "$GPGV_CONF"
apt-get update || echo "(apt update failed; continuing offline)"
for p in "${DOWNGRADE[@]}"; do
    v=$(apt-cache madison "$p" | awk -F'|' 'NR==1 {gsub(/ /,"",$2); print $2}')
    [[ -n $v ]] && apt-get install -y --allow-downgrades "$p=$v" || echo "Could not revert $p; check 'apt-cache policy $p'"
done

if [[ ${#DEBS[@]} -gt 0 ]]; then
    step "4. Reinstalling the previous driver from saved packages"
    apt-get install -y --allow-downgrades "${DEBS[@]}"
fi

# Restore own (non-package) files in /etc/modprobe.d that the purge removed, e.g. nvidia-drm modeset=1.
if [[ -f $STATE_DIR/etc-backup.tar.gz ]]; then
    mapfile -t MISSING < <(tar tvzf "$STATE_DIR/etc-backup.tar.gz" etc/modprobe.d 2>/dev/null \
        | awk '$1 ~ /^-/ {print $NF}' | while read -r f; do [[ -e /$f ]] || echo "$f"; done)
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        tar xzf "$STATE_DIR/etc-backup.tar.gz" -C / "${MISSING[@]}"
        echo "Restored: ${MISSING[*]}"
    fi
fi

update-initramfs -u
echo
echo "Rolled back. Reboot now. Rollback data is kept in $STATE_DIR (delete it when you're happy)."
