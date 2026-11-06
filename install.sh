#!/usr/bin/env bash
# Tom OS Installer TUI - one-line installer for Linux and macOS
#   curl -fsSL https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.sh | bash
#
# Options (environment variables):
#   TOMOS_TUI_PREFIX=/some/dir   install into this bin directory
#   TOMOS_TUI_NO_DESKTOP=1       don't add a menu entry (Linux)
#   TOMOS_TUI_REF=main           branch or tag to install from
set -eu

REF="${TOMOS_TUI_REF:-main}"
URL="${TOMOS_TUI_URL:-https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/$REF/tomos-installer-tui}"
NAME="tomos-installer-tui"

if [ -t 1 ]; then P=$'\033[1;38;5;198m'; C=$'\033[38;5;51m'; G=$'\033[1;38;5;48m'; Y=$'\033[1;38;5;220m'; RD=$'\033[1;38;5;203m'; N=$'\033[0m'
else P=""; C=""; G=""; Y=""; RD=""; N=""; fi
say() { printf '%s==>%s %s\n' "$P" "$N" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RD" "$N" "$*" >&2; exit 1; }

printf '%s\n' "${P}  T O M   O S${N}  ${C}// live USB installer${N}"

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*)
    die "this is the Linux/macOS installer. On Windows, open PowerShell and run:
    irm https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.ps1 | iex" ;;
  *) die "unsupported system: $(uname -s) (Linux, macOS and Windows are supported)" ;;
esac

if [ "$OS" = linux ] && grep -qi microsoft /proc/version 2>/dev/null; then
  warn "this looks like WSL. WSL can't see USB sticks - use the Windows version instead:"
  warn "  irm https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.ps1 | iex"
fi

# ---------------------------------------------------------------- dependencies
missing=""
need() { command -v "$1" >/dev/null 2>&1 || missing="$missing $2"; }
need curl curl
need dd coreutils
if [ "$OS" = linux ]; then
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || missing="$missing coreutils"
  need lsblk util-linux
  [ "$(id -u)" = 0 ] || need sudo sudo
else
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || missing="$missing shasum"
  need diskutil diskutil
fi
if [ -n "$missing" ]; then
  pkgs=$(printf '%s\n' $missing | sort -u | tr '\n' ' ')
  warn "missing: $pkgs"
  if command -v apt-get >/dev/null 2>&1; then warn "install with: sudo apt install $pkgs"
  elif command -v dnf >/dev/null 2>&1; then warn "install with: sudo dnf install $pkgs"
  elif command -v zypper >/dev/null 2>&1; then warn "install with: sudo zypper install $pkgs"
  elif command -v pacman >/dev/null 2>&1; then warn "install with: sudo pacman -S $pkgs"
  fi
fi
command -v curl >/dev/null 2>&1 || die "curl is required"

# ---------------------------------------------------------------- where to install
if [ -n "${TOMOS_TUI_PREFIX:-}" ]; then BIN="$TOMOS_TUI_PREFIX"
elif [ "$(id -u)" = 0 ]; then BIN=/usr/local/bin
else BIN="$HOME/.local/bin"
fi
mkdir -p "$BIN" || die "can't create $BIN"

say "Downloading $NAME ($REF)"
tmp="$(mktemp "${TMPDIR:-/tmp}/tomos-tui.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 "$URL" -o "$tmp" || die "download failed: $URL"
head -n1 "$tmp" | grep -q 'bash' || die "the downloaded file doesn't look right"
bash -n "$tmp" || die "the downloaded script has errors"
chmod 755 "$tmp"
mv -f "$tmp" "$BIN/$NAME"
trap - EXIT
say "Installed $BIN/$NAME ($("$BIN/$NAME" --version 2>/dev/null | awk '{print $2}'))"

# ---------------------------------------------------------------- PATH
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    shell_rc=""
    case "${SHELL:-}" in
      */zsh) shell_rc="$HOME/.zshrc" ;;
      */bash) if [ "$OS" = mac ]; then shell_rc="$HOME/.bash_profile"; else shell_rc="$HOME/.bashrc"; fi ;;
      */fish) shell_rc="" ;;
      *) shell_rc="$HOME/.profile" ;;
    esac
    if [ -n "$shell_rc" ] && ! grep -qs "$BIN" "$shell_rc"; then
      printf '\n# added by the Tom OS Installer TUI\nexport PATH="%s:$PATH"\n' "$BIN" >>"$shell_rc"
      warn "$BIN was not on your PATH - added it to $shell_rc (open a new terminal)"
    else
      warn "$BIN is not on your PATH - run it as $BIN/$NAME"
    fi ;;
esac

# ---------------------------------------------------------------- menu entry (Linux)
if [ "$OS" = linux ] && [ -z "${TOMOS_TUI_NO_DESKTOP:-}" ] && [ "$(id -u)" != 0 ]; then
  apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  term=""
  for t in kitty gnome-terminal konsole xfce4-terminal alacritty foot wezterm xterm; do
    command -v "$t" >/dev/null 2>&1 && { term="$t"; break; }
  done
  if [ -n "$term" ] && mkdir -p "$apps" 2>/dev/null; then
    case "$term" in
      gnome-terminal) exec_line="gnome-terminal -- $BIN/$NAME" ;;
      konsole|xfce4-terminal|xterm|alacritty|foot|kitty) exec_line="$term -e $BIN/$NAME" ;;
      wezterm) exec_line="wezterm start -- $BIN/$NAME" ;;
    esac
    cat >"$apps/tomos-installer-tui.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Tom OS Installer TUI
Comment=Download Tom OS and burn it to a USB stick
Exec=$exec_line
Icon=media-removable
Terminal=false
Categories=System;Utility;
EOF
    say "Added a menu entry (opens in $term)"
  fi
fi

printf '\n%s✔ Done.%s Run %s%s%s to start, or %s%s --help%s for the command line.\n' "$G" "$N" "$C" "$NAME" "$N" "$C" "$NAME" "$N"
