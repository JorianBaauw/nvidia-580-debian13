# NVIDIA 580 driver on Debian 13 for Maxwell, Pascal and Volta GPUs

Scripts that install NVIDIA's **580 LTS** driver on **Debian 13 (Trixie)** for older GPUs, such as the GTX 900/1000 series and Quadro M/P series. They save everything needed to **roll back** first, so you can return to your previous driver even without network access.

They automate the method described on the [Debian wiki](https://wiki.debian.org/NvidiaGraphicsDrivers) ("Maxwell, Pascal and Volta GPUs on Trixie"), and add safety checks and a rollback.

> [!WARNING]
> This installs packages from NVIDIA's **Debian 12** repository on Debian 13. The Debian wiki calls it "a bit of a dirty hack and borderline FrankenDebian". It works, but you are leaving Debian's supported path. Read [Caveats](#caveats) first.

## Why

| Driver | Status for Maxwell, Pascal and Volta on Debian 13 |
|---|---|
| Debian's `nvidia-driver` 550 | The default. Unmaintained with known security issues, according to the Debian wiki. It won't build on kernels 6.16 and newer. |
| NVIDIA 590 and newer (NVIDIA's Debian 13 repo) | Doesn't support these GPUs. Only Turing (RTX 20 series) and newer. |
| **NVIDIA 580 LTS** | The last branch that supports these GPUs, with updates until **June 2028**. It's only in NVIDIA's Debian 12 repo. |
| nouveau | Maintained, but on Pascal it can't reclock, so 3D performance is very low. No CUDA or NVENC. |

If you only use the NVIDIA GPU to drive an external monitor and don't need CUDA, NVENC or 3D performance, **nouveau** is the simpler choice.

## Is this for you?

- Debian 13 (trixie), **amd64**
- GPU codename starting with **GM**, **GP** or **GV** (Maxwell, Pascal, Volta). Check with:
  ```
  lspci -nn | grep -i nvidia
  ```
  For example, `GP107GLM [Quadro P1000 Mobile]` and `GP104 [GeForce GTX 1070]` qualify.
- Your current driver is Debian's `nvidia-driver` package or nouveau. If you used NVIDIA's `.run` installer, run `sudo nvidia-uninstall` first.

The script checks all of this and refuses to run otherwise. It sends Kepler cards (GK) and Turing or newer cards to the right alternative.

## Usage

```bash
git clone https://github.com/JorianBaauw/nvidia-580-debian13.git
cd nvidia-580-debian13
sudo ./install.sh
# reboot
nvidia-smi
```

Run it from a normal terminal. It asks for confirmation before the steps that change something, and shows a preview before it touches the driver.

### What `install.sh` does

1. **Checks.** Debian 13, amd64, a supported GPU, no `.run` install, no previous run, and Secure Boot status.
2. **Saves rollback data** to `/var/backups/nvidia-580-switch/`:
   - the list of installed driver packages
   - **offline copies of those `.deb` files**
   - a backup of `/etc/apt`, `/etc/modprobe.d`, `/etc/nvidia` and `/etc/X11`
3. **Adds NVIDIA's Debian 12 repo** following the wiki, with a few changes:
   - It uses **https** instead of http.
   - It tries **without** `allow-insecure=yes` first, and only asks to add it if apt rejects the signature.
   - It **pins `dkms`** (and any other non-driver package the repo would upgrade) to Debian's version. Otherwise `apt upgrade` would replace Debian's `dkms` with NVIDIA's Debian 12 build.
4. **Pins the 580 branch** with `nvidia-driver-pinning-580`, then checks that 580 is what apt would install.
5. **Shows a preview**, removes the old driver and installs `cuda-drivers`. The proprietary flavor is required for these GPUs.
6. **Configures the system:**
   - blacklists nouveau
   - sets `nvidia-drm modeset=1`
   - turns on `NVreg_PreserveVideoMemoryAllocations=1` and enables the suspend/resume/hibernate services, so apps and the desktop survive suspend
   - rebuilds the initramfs

Your current driver keeps running until step 5, so if the repo setup fails, you're not left without a driver.

## Rollback

```bash
sudo ./rollback.sh
# reboot
```

The rollback:

1. Purges exactly the packages installed from NVIDIA's repo, matched by package **and** version against the repo index.
2. Removes the repo, key, apt config and modprobe changes.
3. Reinstalls your previous driver from the saved `.deb` files. **No network needed.**
4. Restores your own files in `/etc/modprobe.d` that the purge removed.

If you were on nouveau before, you end up on nouveau again.

### If the desktop doesn't come up after rebooting

1. Switch to a text console with **Ctrl+Alt+F3**, log in and run `sudo ./rollback.sh`.
2. If that doesn't work either, edit the boot entry at the GRUB menu (press `e`) and add this to the end of the line starting with `linux`:
   ```
   modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm
   ```
   Boot with **Ctrl+X**, then run the rollback.

On laptops with Intel/AMD + NVIDIA hybrid graphics, the built-in screen is usually driven by the integrated GPU, so it normally keeps working even if the NVIDIA driver doesn't load.

## Caveats

- **apt's signature checker changes.** Debian 13 rejects the SHA1 signatures on NVIDIA's Debian 12 repo since 2026-02-01, so the wiki's method switches apt to `gpgv` (`/etc/apt/apt.conf.d/10gpgv`). That applies to **all** repositories. The rollback undoes it.
- **No 32-bit libraries.** NVIDIA's repo has no i386 packages, so 32-bit apps (Steam, Wine) lose NVIDIA acceleration. The script warns you if you have them installed.
- **Secure Boot.** DKMS signs the module with `/var/lib/dkms/mok.key`. If that key isn't enrolled, the script tells you to run `sudo mokutil --import /var/lib/dkms/mok.pub` and enroll it on the next boot.
- **No full power-off when idle.** Pascal and older don't support runtime D3, so on laptops the NVIDIA GPU idles at a low-power state (P8) instead of switching off. That's the same as with the 550 driver.
- **Hybrid laptops (KDE Plasma and other Wayland desktops):** let the compositor render on the integrated GPU, which is the default. Forcing it onto the NVIDIA GPU, for example with `KWIN_DRM_DEVICES`, led to compositor crashes after GPU resets in my case.
- **Upgrading to Debian 14** will need a different setup. Run the rollback (or purge the driver) before a release upgrade.

## Tested on

- HP ZBook Studio x360 G5: Intel UHD 630 + **Quadro P1000 Mobile (GP107)**
- Debian 13, kernel 6.12.111, KDE Plasma 6.3 (Wayland)
- Switched from Debian `nvidia-driver` 550.163.01 to **580.178.04**

The steps were run on this machine with an earlier, machine-specific version of these scripts. The generic `install.sh` and `rollback.sh` have so far only been dry-tested: syntax, GPU detection and rollback package detection. Feedback and issues are welcome.

## Credits

- The method comes from the [Debian wiki: NvidiaGraphicsDrivers](https://wiki.debian.org/NvidiaGraphicsDrivers) and its contributors.
- NVIDIA driver packages come from [NVIDIA's CUDA repository](https://developer.download.nvidia.com/compute/cuda/repos/).

## License

[MIT](LICENSE). No warranty: you run this on your own system at your own risk.
