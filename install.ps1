# imake installer for Windows: fetches the latest prebuilt binary from
# GitHub Releases and adds it to the user PATH. Usage:
#   irm https://raw.githubusercontent.com/gshireesh/imake_public/main/install.ps1 | iex
#
# Overrides:
#   IMAKE_INSTALL_DIR  target directory (default: %LOCALAPPDATA%\Programs\imake)
#   IMAKE_BASE_URL     alternate download base (used by local testing)
$ErrorActionPreference = "Stop"

$Repo = "gshireesh/imake_public"
$Base = if ($env:IMAKE_BASE_URL) { $env:IMAKE_BASE_URL } else { "https://github.com/$Repo/releases/latest/download" }

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    "X64" { "amd64" }
    "Arm64" { "arm64" }
    default { Write-Error "imake: unsupported architecture"; exit 1 }
}

$Dir = if ($env:IMAKE_INSTALL_DIR) {
    $env:IMAKE_INSTALL_DIR
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "Programs\imake"
} else {
    Join-Path $HOME ".local/bin"
}
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$asset = "imake_windows_$arch.zip"
$zip = Join-Path ([IO.Path]::GetTempPath()) $asset
Write-Host "Downloading $Base/$asset"
Invoke-WebRequest -Uri "$Base/$asset" -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $Dir -Force
Remove-Item $zip

$exe = Join-Path $Dir "imake.exe"
Write-Host "Installed imake to $exe"

if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
    # Persist the install dir on the user PATH so no manual step is
    # needed; also update the current session.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not ($userPath -split ";" -contains $Dir)) {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$Dir", "User")
        Write-Host "Added $Dir to your user PATH - restart your terminal to pick it up"
    }
    if (-not (($env:Path -split ";") -contains $Dir)) {
        $env:Path = "$env:Path;$Dir"
    }
    & $exe --version
} else {
    Write-Host "(non-Windows PowerShell: skipping PATH registration)"
}
