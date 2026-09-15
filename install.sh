#!/bin/sh
# imake installer: fetches the latest prebuilt binary from GitHub
# Releases. Works on macOS, Linux, and Windows (Git Bash / MSYS).
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gshireesh/imake_public/main/install.sh | sh
#
# Overrides:
#   IMAKE_INSTALL_DIR  target directory (skips the default logic below)
#   IMAKE_BASE_URL     alternate download base (used by local testing)
#
# Defaults: never sudo. On macOS/Linux, an existing imake is upgraded in
# place when its directory is writable; otherwise imake goes to a
# per-user bin directory already on your PATH (~/.local/bin, ~/bin, or
# another stable directory under $HOME), else ~/.local/bin added to your
# shell's PATH. On Windows, %LOCALAPPDATA%\Programs\imake added to the
# user PATH.
set -eu

REPO="gshireesh/imake_public"
BASE="${IMAKE_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

os=$(uname -s)
case "$os" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) echo "imake: unsupported OS: $os" >&2; exit 1 ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "imake: unsupported architecture: $arch" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
  echo "Downloading $1"
  curl -fsSL "$1" -o "$2"
}

if [ "$os" = windows ]; then
  bin=imake.exe
  if [ -n "${IMAKE_INSTALL_DIR:-}" ]; then
    dir="$IMAKE_INSTALL_DIR"
  else
    localapp="${LOCALAPPDATA:-$HOME/AppData/Local}"
    if command -v cygpath >/dev/null 2>&1; then
      localapp=$(cygpath -u "$localapp")
    fi
    dir="$localapp/Programs/imake"
  fi
  mkdir -p "$dir"

  fetch "$BASE/imake_windows_${arch}.zip" "$tmp/imake.zip"
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$tmp/imake.zip" -d "$tmp"
  elif command -v powershell.exe >/dev/null 2>&1; then
    winzip=$(cygpath -w "$tmp/imake.zip" 2>/dev/null || echo "$tmp/imake.zip")
    windst=$(cygpath -w "$tmp" 2>/dev/null || echo "$tmp")
    powershell.exe -NoProfile -Command "Expand-Archive -Path '$winzip' -DestinationPath '$windst' -Force"
  else
    echo "imake: need unzip or powershell.exe to extract the archive" >&2
    exit 1
  fi
  cp "$tmp/$bin" "$dir/$bin"
  echo "Installed imake to $dir/$bin"
  "$dir/$bin" --version || true

  # Persist the install dir on the Windows user PATH (idempotent).
  if command -v powershell.exe >/dev/null 2>&1; then
    windir=$(cygpath -w "$dir" 2>/dev/null || echo "$dir")
    powershell.exe -NoProfile -Command "
      \$p = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not ((\$p -split ';') -contains '$windir')) {
        [Environment]::SetEnvironmentVariable('Path', \"\$p;$windir\", 'User')
        Write-Host 'Added $windir to your user PATH - restart your terminal to pick it up'
      }
    "
  else
    echo "NOTE: add $dir to your PATH"
  fi
  exit 0
fi

# macOS / Linux
fetch "$BASE/imake_${os}_${arch}.tar.gz" "$tmp/imake.tar.gz"
tar -xzf "$tmp/imake.tar.gz" -C "$tmp"

# user_bin_dir prints the first writable, stable directory under $HOME
# on PATH, preferring ~/.local/bin and ~/bin. Version-manager and app
# directories are skipped: they come and go (a new node version, an app
# update) and would take imake with them.
user_bin_dir() {
  for want in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$want:"*) [ -w "$want" ] && { echo "$want"; return; } ;; esac
  done
  old_ifs=$IFS
  IFS=:
  for d in $PATH; do
    case "$d" in
      "$HOME"/*) ;;
      *) continue ;;
    esac
    case "$d/" in
      */.nvm/* | */.sdkman/* | */.pyenv/* | */.rbenv/* | */.asdf/* | */.volta/* | */.fnm/* | \
        */.jenv/* | */.goenv/* | */node_modules/* | */shims/* | */.docker/* | */Library/* | */Applications/*) continue ;;
    esac
    if [ -d "$d" ] && [ -w "$d" ]; then
      IFS=$old_ifs
      echo "$d"
      return
    fi
  done
  IFS=$old_ifs
}

existing=$(command -v imake 2>/dev/null || true)
if [ -n "${IMAKE_INSTALL_DIR:-}" ]; then
  dir="$IMAKE_INSTALL_DIR"
elif [ -n "$existing" ] && [ -w "$(dirname "$existing")" ]; then
  dir=$(dirname "$existing")
else
  dir=$(user_bin_dir)
  [ -n "$dir" ] || dir="$HOME/.local/bin"
fi

mkdir -p "$dir"
install -m 0755 "$tmp/imake" "$dir/imake"
echo "Installed imake to $dir/imake"
"$dir/imake" --version || true

# Make sure the chosen directory is on PATH; for the ~/.local/bin
# fallback, persist it in the shell rc so no manual step is needed.
case ":$PATH:" in
  *":$dir:"*) ;;
  *)
    if [ "$dir" = "$HOME/.local/bin" ]; then
      line='export PATH="$HOME/.local/bin:$PATH"'
      case "${SHELL:-}" in
        */zsh) rc="$HOME/.zshrc" ;;
        */bash) rc="$HOME/.bashrc" ;;
        */fish) rc="" ;;
        *) rc="$HOME/.profile" ;;
      esac
      if [ -n "$rc" ]; then
        if ! grep -qsF '.local/bin' "$rc"; then
          printf '\n# added by imake installer\n%s\n' "$line" >>"$rc"
          prepended=1
          echo "Added ~/.local/bin to PATH in $rc — restart your shell or run:"
          echo "  $line"
        else
          echo "~/.local/bin is already in $rc — restart your shell to pick it up"
        fi
      else
        echo "Add ~/.local/bin to your PATH: fish_add_path \$HOME/.local/bin"
      fi
    else
      echo "NOTE: $dir is not in your PATH"
    fi
    ;;
esac

# An older imake earlier on PATH (e.g. a sudo install in /usr/local/bin)
# would keep winning; say how to retire it.
# (Not when ~/.local/bin was just prepended in the rc: after a restart
# the new copy comes first anyway.)
first=$(command -v imake 2>/dev/null || true)
if [ -z "${prepended:-}" ] && [ -n "$first" ] && [ "$first" != "$dir/imake" ]; then
  echo "NOTE: $first comes first on your PATH and will still run - remove it once:"
  if [ -w "$(dirname "$first")" ]; then
    echo "  rm $first"
  else
    echo "  sudo rm $first"
  fi
fi
