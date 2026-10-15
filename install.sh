#!/bin/bash
# Install NVIDIA's 580 LTS driver on Debian 13 (Trixie) for Maxwell / Pascal / Volta GPUs,
# using NVIDIA's Debian 12 CUDA repository, as described on
# https://wiki.debian.org/NvidiaGraphicsDrivers ("Maxwell, Pascal and Volta GPUs on Trixie").
#
# Saves everything needed to undo it (incl. offline copies of the current driver packages)
# to $STATE_DIR first. Undo with: sudo ./rollback.sh
#
# Usage: sudo ./install.sh
set -euo pipefail

STATE_DIR=${STATE_DIR:-/var/backups/nvidia-580-switch}
REPO_URL=https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/
KEYRING_DEB=${REPO_URL}cuda-keyring_1.1-1_all.deb
REPO_LIST=/etc/apt/sources.list.d/nvidia-d12.list
REPO_KEY=/etc/apt/keyrings/nvidia-d12-archive.key
GPGV_CONF=/etc/apt/apt.conf.d/10gpgv
GPGV_LINE='APT::Key::GPGVCommand "/usr/bin/gpgv";'
PIN_FILE=/etc/apt/preferences.d/nvidia-580-no-debian-overrides
MODPROBE_CONF=/etc/modprobe.d/nvidia-580-local.conf
# Package names that belong to the NVIDIA driver stack (Debian's or NVIDIA's packaging).
DRIVER_RE='^(nvidia-|libnvidia-|libcuda|libnvcuvid|libnvoptix|libgl1-nvidia|libgles-nvidia|libglx-nvidia|libegl-nvidia|glx-alternative-|xserver-xorg-video-nvidia|firmware-nvidia|libxnvctrl|cuda-drivers)'

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
step() { echo; echo "=== $* ==="; }
confirm() { local a; read -rp "$1 [y/N] " a; [[ $a == [yY] ]] || { echo "Aborted, nothing further changed."; exit 1; }; }

# ---------------------------------------------------------------- checks
step "Checking system"
[[ $EUID -eq 0 ]] || die "run with sudo"
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || die "this is for Debian 13 (trixie), found ${PRETTY_NAME:-unknown}"
[[ $(dpkg --print-architecture) == amd64 ]] || die "only amd64 is supported (the only arch the wiki method was tested on)"
command -v lspci >/dev/null || apt-get install -y pciutils
command -v wget >/dev/null || apt-get install -y wget
[[ -x /usr/bin/gpgv ]] || apt-get install -y gpgv

mapfile -t GPUS < <(lspci -d 10de: -nn | grep -E '\[03(00|02)\]' || true)
[[ ${#GPUS[@]} -gt 0 ]] || die "no NVIDIA GPU found"
for g in "${GPUS[@]}"; do
    echo "GPU: $g"
    chip=$(grep -oE '\b(GK|GM|GP|GV|TU|GA|AD|GH|GB)[0-9]{3}' <<<"$g" | head -1 || true)
    case $chip in
        GM*|GP*|GV*) echo "  -> ${chip}: Maxwell/Pascal/Volta, supported by 580 LTS" ;;
        GK*) die "${chip} is Kepler; the newest driver for it is 470, not 580" ;;
        TU*|GA*|AD*|GH*|GB*) die "${chip} is Turing or newer; use NVIDIA's Debian 13 repo with 'nvidia-open' instead (see the wiki)" ;;
        *) warn "could not determine the GPU generation from the name"; confirm "Continue anyway?" ;;
    esac
done

[[ -e /usr/bin/nvidia-uninstall ]] && die "a driver installed with NVIDIA's .run installer was found; run 'nvidia-uninstall' first"
dpkg-query -W -f '${db:Status-Abbrev}' cuda-drivers 2>/dev/null | grep -q '^ii' && die "cuda-drivers is already installed"
for f in "$REPO_LIST" "$PIN_FILE" "$MODPROBE_CONF"; do
    [[ -e $f ]] && die "$f already exists (previous run?). Run rollback.sh or remove it first"
done
if [[ -e $GPGV_CONF ]] && [[ $(cat "$GPGV_CONF") != "$GPGV_LINE" ]]; then
    die "$GPGV_CONF exists with other content; refusing to overwrite"
fi
[[ -e $STATE_DIR ]] && die "$STATE_DIR already exists (previous run?). Move it away first"

SECUREBOOT=0
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    SECUREBOOT=1
    warn "Secure Boot is enabled. DKMS signs the module with /var/lib/dkms/mok.key;"
    warn "that key must be enrolled (mokutil --import) or the driver won't load. The script checks this at the end."
fi

mapfile -t OLD < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}:${Architecture}=${Version}\n' \
    | awk '$1 ~ /^[ih]i/ {print $2}' | grep -E "$DRIVER_RE" || true)
if [[ ${#OLD[@]} -gt 0 ]]; then
    echo "Currently installed NVIDIA driver packages: ${#OLD[@]} (e.g. $(grep -m1 '^nvidia-driver[:=]' <<<"$(printf '%s\n' "${OLD[@]}")" || echo "${OLD[0]}"))"
else
    echo "No packaged NVIDIA driver installed (nouveau). Rollback will return to nouveau."
fi
I386=$(printf '%s\n' "${OLD[@]}" | grep -c ':i386=' || true)
[[ $I386 -gt 0 ]] && warn "$I386 32-bit (i386) NVIDIA libraries are installed; NVIDIA's repo has no i386 packages, so 32-bit apps (Steam, Wine) lose NVIDIA acceleration"
confirm "Continue? (next: save rollback data, add NVIDIA repo; driver is not touched yet)"

# ---------------------------------------------------------------- rollback data
step "1. Saving rollback data to $STATE_DIR"
mkdir -p "$STATE_DIR/debs"
chmod 700 "$STATE_DIR"
printf '%s\n' "${OLD[@]}" > "$STATE_DIR/packages-before.txt"
tar czf "$STATE_DIR/etc-backup.tar.gz" -C / etc/apt etc/modprobe.d $( [[ -d /etc/nvidia ]] && echo etc/nvidia ) $( [[ -d /etc/X11 ]] && echo etc/X11 )
if [[ ${#OLD[@]} -gt 0 ]]; then
    chown _apt "$STATE_DIR/debs" 2>/dev/null || true
    (cd "$STATE_DIR/debs" && apt-get download "${OLD[@]}") \
        || die "could not download the current driver packages for offline rollback (are those versions still in the archive?)"
    chown -R root:root "$STATE_DIR/debs"
    echo "Saved $(ls "$STATE_DIR/debs" | wc -l) packages ($(du -sh "$STATE_DIR/debs" | cut -f1))"
fi

# ---------------------------------------------------------------- repo
step "2. Adding NVIDIA's Debian 12 repository"
echo "$GPGV_LINE" > "$GPGV_CONF"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
wget -qO "$tmp/keyring.deb" "$KEYRING_DEB"
dpkg -x "$tmp/keyring.deb" "$tmp/x"
install -D -m 644 "$tmp/x/usr/share/keyrings/cuda-archive-keyring.gpg" "$REPO_KEY"
# NVIDIA's repo also carries newer versions of some Debian packages (e.g. dkms). Never take those from it.
cat > "$PIN_FILE" <<'EOF'
# Added by nvidia-580-debian13 install.sh: only take driver packages from NVIDIA's Debian 12 repo.
Package: dkms
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF
# https and no allow-insecure first; only relax if apt rejects the repo signature.
echo "deb [signed-by=$REPO_KEY] $REPO_URL /" > "$REPO_LIST"
update_out=$(apt-get update 2>&1 || true)
echo "$update_out"
if grep -qiE '^(E|W|Err):.*developer\.download\.nvidia\.com' <<<"$update_out"; then
    echo
    echo "apt rejected the NVIDIA repo signature. The wiki's workaround is allow-insecure=yes for this repo (still over https)."
    confirm "Apply allow-insecure=yes to the NVIDIA repo?"
    echo "deb [signed-by=$REPO_KEY allow-insecure=yes] $REPO_URL /" > "$REPO_LIST"
    apt-get update
fi

step "3. Pinning the driver to the 580 branch"
apt-get install -y nvidia-driver-pinning-580
apt-get update
cand=$(apt-cache policy cuda-drivers | awk '/Candidate:/ {print $2}')
[[ $cand == 580* ]] || die "cuda-drivers candidate is '$cand', expected 580.x. Run rollback.sh to undo the repo changes"

# Block any other non-driver package the NVIDIA repo would upgrade.
mapfile -t EXTRA < <(apt-get -s upgrade 2>/dev/null | awk '/^Inst/ && /developer\.download\.nvidia\.com/ {print $2}' \
    | grep -vE "$DRIVER_RE" | grep -vx dkms || true)
if [[ ${#EXTRA[@]} -gt 0 ]]; then
    echo "Also blocking from NVIDIA's repo: ${EXTRA[*]}"
    printf '\nPackage: %s\nPin: origin developer.download.nvidia.com\nPin-Priority: -1\n' "${EXTRA[*]}" >> "$PIN_FILE"
fi

# ---------------------------------------------------------------- switch
step "4. Preview (nothing changes yet)"
if [[ ${#OLD[@]} -gt 0 ]]; then
    mapfile -t OLD_NAMES < <(printf '%s\n' "${OLD[@]}" | sed 's/=.*//')
    other=$(apt-get -s purge "${OLD_NAMES[@]}" | awk '/^(Purg|Remv)/ {print $2}' | grep -vE "$DRIVER_RE" || true)
    [[ -n $other ]] && { warn "removing the old driver also removes these non-driver packages:"; echo "$other"; }
fi
echo "cuda-drivers will install:"
apt-get -s install cuda-drivers | awk '/^Inst/ {print "  + " $2 " " $3 " " $4}' | head -80 || true
confirm "Remove the current driver and install NVIDIA 580 now?"

if [[ ${#OLD[@]} -gt 0 ]]; then
    step "5. Removing the current driver"
    apt-get purge -y "${OLD_NAMES[@]}"
fi

step "6. Installing NVIDIA 580 (DKMS build takes a few minutes)"
apt-get install -y cuda-drivers

step "7. Post-install configuration"
cat > "$MODPROBE_CONF" <<'EOF'
# Added by nvidia-580-debian13 install.sh
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1
# Keep video memory across suspend/resume (needs nvidia-suspend/resume/hibernate services)
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
EOF
for s in nvidia-suspend nvidia-resume nvidia-hibernate; do
    systemctl enable "$s.service" 2>/dev/null && echo "enabled $s" || warn "$s.service not found"
done
dkms status nvidia || true
ls /lib/modules/"$(uname -r)"/updates/dkms/nvidia.ko* >/dev/null 2>&1 \
    || warn "no nvidia module built for the running kernel $(uname -r); check 'dkms status' and /var/lib/dkms/nvidia/*/build/make.log"
update-initramfs -u

if [[ $SECUREBOOT -eq 1 && -f /var/lib/dkms/mok.pub ]] && ! mokutil --test-key /var/lib/dkms/mok.pub 2>&1 | grep -qi 'already enrolled'; then
    echo
    warn "Secure Boot is on and the DKMS signing key is not enrolled yet. Run:"
    echo "    sudo mokutil --import /var/lib/dkms/mok.pub"
    echo "  choose a one-time password, reboot, and pick 'Enroll MOK' in the blue MokManager screen."
fi

echo
echo "Done. Reboot, then check with: nvidia-smi"
echo "To undo: sudo $(cd "$(dirname "$0")" && pwd)/rollback.sh   (rollback data: $STATE_DIR)"
