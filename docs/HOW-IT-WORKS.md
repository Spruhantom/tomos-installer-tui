# How it works

## Files

| File | What it is |
|---|---|
| `tomos-installer-tui` | The app for Linux and macOS. One Bash file, works with Bash 3.2 (the macOS default). |
| `tomos-installer-tui.ps1` | The app for Windows. One PowerShell file, works with PowerShell 5.1 and 7. Saved as UTF-8 with BOM so 5.1 reads it correctly. |
| `install.sh` | One-line installer for Linux/macOS. |
| `install.ps1` | One-line installer for Windows. |
| `.github/workflows/test.yml` | Tests on Ubuntu, macOS and Windows. |

## Finding the release

The app reads the latest release of `Spruhantom/tom-os-hyperland1` from the GitHub API (falling back to the tags list), then fetches `download/tomos-VERSION-amd64.iso.sha256` and `download/parts.sha256`. The ISO is stored as parts because of GitHub's file-size limit; they're downloaded from `media.githubusercontent.com`.

## Downloading

- Each part is downloaded with resume (`curl -C -` on Linux/macOS, an HTTP `Range` request on Windows).
- Each part is checked against `parts.sha256`; a finished, verified part gets a `.ok` marker so it isn't checked again.
- The parts are joined into the ISO and the whole image is checked against the release SHA-256. A verified ISO is reused next time.

## Finding drives

| | Source | Removable means | System disk means |
|---|---|---|---|
| Linux | `lsblk -J -b` | `RM=1`, or `TRAN=usb` | has `/`, `/boot`, `/boot/efi` or `[SWAP]` mounted |
| macOS | `diskutil list -plist physical` + `diskutil info` | removable media, or USB / SD protocol | contains the boot volume, or is its APFS physical store |
| Windows | `Get-Disk` | `BusType` USB, SD or MMC | `IsBoot` or `IsSystem`, or holds `C:` |

Only removable disks can be selected. `TOMOS_TUI_ALLOW_DEVICE` can add one by name.

## Burning

**Linux**: unmounts every partition (`udisksctl` / `umount`), then
`dd if=ISO of=/dev/sdX bs=4M oflag=direct conv=sync,fsync status=progress`, then `sync` and `blockdev --rereadpt`.

**macOS**: `diskutil unmountDisk force /dev/diskN`, then `dd` to the raw `/dev/rdiskN` (much faster), then `diskutil eject`.

**Windows**: runs `diskpart` `clean` to remove the partitions and stop Windows mounting them, then writes `\\.\PhysicalDriveN` in 4 MiB chunks through a small built-in C# helper (`CreateFile` with no buffering + write-through). The first 4 MiB are written last, so a half-written stick never looks bootable. It then flushes, asks Windows to re-read the disk (`IOCTL_DISK_UPDATE_PROPERTIES`) and runs `Update-Disk`. If the app isn't running as admin, it starts the burn step in an elevated window with a UAC prompt.

## Verifying

The app reads back exactly as many bytes as the image and computes SHA-256 while reading, then compares it with the image's hash.

## Tests

The CI builds a small fake release (9 MB in 3 parts), serves it on `localhost:8765` and points the app at it with `TOMOS_TUI_BASE_URL`. It burns to a real block device (loop device, RAM disk, VHD) and checks the result with an independent reader. `TOMOS_TUI_FAKE_DRIVES` is used only for screenshots and the safety-rule tests.
