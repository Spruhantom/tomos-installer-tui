# Tom OS Installer TUI - one-line installer for Windows 10 and 11
#   irm https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.ps1 | iex
#
# Installs into %LOCALAPPDATA%\TomOS\installer-tui, adds "tomos-installer-tui" to your PATH
# and a "Tom OS Installer TUI" Start menu shortcut. No Administrator rights needed to install.

& {
  $ErrorActionPreference = 'Stop'
  $ref = if ($env:TOMOS_TUI_REF) { $env:TOMOS_TUI_REF } else { 'main' }
  $url = "https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/$ref/tomos-installer-tui.ps1"
  if ($env:TOMOS_TUI_URL) { $url = $env:TOMOS_TUI_URL }
  $E = [char]27
  $P = "$E[1;38;5;198m"; $C = "$E[38;5;51m"; $G = "$E[1;38;5;48m"; $Y = "$E[1;38;5;220m"; $N = "$E[0m"
  function Say($m) { Write-Host "$P==>$N $m" }

  Write-Host "$P  T O M   O S$N  $C// live USB installer$N"

  $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
  if (-not $onWindows) {
    Write-Host "${Y}This is the Windows installer.$N On Linux and macOS run:"
    Write-Host '  curl -fsSL https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.sh | bash'
    return
  }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

  $dir = Join-Path $env:LOCALAPPDATA 'TomOS\installer-tui'
  $bin = Join-Path $dir 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  $script = Join-Path $dir 'tomos-installer-tui.ps1'

  Say "Downloading tomos-installer-tui ($ref)"
  $tmp = "$script.new"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
  $errors = $null; $tokens = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count) { Remove-Item $tmp -Force; throw "the downloaded script has errors: $($errors[0].Message)" }
  Move-Item -Force $tmp $script
  try { Unblock-File -LiteralPath $script } catch {}

  # command-line launcher
  $cmd = Join-Path $bin 'tomos-installer-tui.cmd'
  Set-Content -LiteralPath $cmd -Encoding ASCII -Value @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tomos-installer-tui.ps1" %*
"@
  Say "Installed $cmd"

  # PATH (user)
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ';' + $bin).TrimStart(';')), 'User')
    Say "Added $bin to your PATH (new terminals pick it up)"
  }
  if (($env:Path -split ';') -notcontains $bin) { $env:Path = "$env:Path;$bin" }

  # Start menu shortcut - opens in Windows Terminal when it's installed (best colours and fonts)
  try {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Tom OS Installer TUI.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) { $s.TargetPath = $wt.Source; $s.Arguments = "powershell.exe $psArgs" }
    else { $s.TargetPath = (Get-Command powershell.exe).Source; $s.Arguments = $psArgs }
    $s.Description = 'Download Tom OS and burn it to a USB stick'
    $s.IconLocation = "$env:SystemRoot\System32\imageres.dll,30"
    $s.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
    $s.Save()
    Say 'Added "Tom OS Installer TUI" to the Start menu'
  } catch { Write-Host "${Y}warning:$N could not create the Start menu shortcut ($($_.Exception.Message))" }

  Write-Host ''
  Write-Host "$G$([char]0x221A) Done.$N Run ${C}tomos-installer-tui$N (or open it from the Start menu)."
  Write-Host "  Burning asks for Administrator permission. Command line: ${C}tomos-installer-tui --help$N"
}
