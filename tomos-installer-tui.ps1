<#
  Tom OS Installer TUI for Windows - download Tom OS and burn it to a USB stick.
  https://github.com/Spruhantom/tomos-installer-tui   (MIT licence)

  Works in Windows PowerShell 5.1 (built into Windows 10 and 11) and PowerShell 7.
  Same screens and options as the Linux/macOS version (tomos-installer-tui).

  Usage:  tomos-installer-tui            full-screen app
          tomos-installer-tui --help     command-line options
#>

$ErrorActionPreference = 'Stop'
$TUI_VERSION = '1.0.0'
$OWNER = 'Spruhantom'; $REPO = 'tom-os-hyperland1'; $BRANCH = 'main'
$DEFAULT_TOMOS_VERSION = '26.10'
$BaseOverride = $env:TOMOS_TUI_BASE_URL
if ($BaseOverride) { $RAW_BASE = "$BaseOverride/download"; $LFS_BASE = "$BaseOverride/download" }
else {
  $RAW_BASE = "https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/download"
  $LFS_BASE = "https://media.githubusercontent.com/media/$OWNER/$REPO/$BRANCH/download"
}
$API_LATEST = "https://api.github.com/repos/$OWNER/$REPO/releases/latest"
$BS = 4194304   # 4 MiB
$IsWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ state
$TS = @{
  IsoPath = ''; IsoSize = [int64]0; IsoVerified = $false; IsoSha = ''
  Drive = $null
  Version = ''; IsoName = ''; TotalSize = [int64]0; RemoteSha = ''; Parts = @()
  ManifestError = ''
  ShowAll = $false; Verify = $true
  Message = ''; Kind = 'info'
  InTui = $false
}
function Get-DownloadDir {
  if ($env:TOMOS_TUI_DIR) { return $env:TOMOS_TUI_DIR }
  $h = [Environment]::GetFolderPath('UserProfile')
  return (Join-Path (Join-Path $h 'Downloads') 'TomOS')
}
$DL_DIR = Get-DownloadDir

# ------------------------------------------------------------------ colours
$E = [char]27
$C0 = "${E}[0m"; $CB = "${E}[1m"; $DIM = "${E}[2m"
$PINK = "${E}[38;5;198m"; $CYAN = "${E}[38;5;51m"; $PURPLE = "${E}[38;5;135m"; $MUTED = "${E}[38;5;103m"
$GREEN = "${E}[38;5;48m"; $RED = "${E}[38;5;203m"; $YELLOW = "${E}[38;5;220m"; $WHITE = "${E}[38;5;255m"
$BGSEL = "${E}[48;5;53m"
$GRAD = @(198, 199, 200, 164, 165, 129, 135, 99, 63, 69, 75, 45, 51)
# glyphs that exist in Consolas / Cascadia (the Windows console fonts)
$G_OK = [string][char]0x221A; $G_SEL = [string][char]0x25BA; $G_DOT = [string][char]0x25CF
$G_USB = [string][char]0x25A0; $G_DISK = [string][char]0x25A1; $G_NO = [string][char]0x00D7
$G_FULL = [string][char]0x2588; $G_EMPTY = [string][char]0x2591; $G_CUR = [string][char]0x2590
$G_ELL = [string][char]0x2026; $G_DASH = [string][char]0x2014; $G_MID = [string][char]0x00B7

function Write-Err($m) { [Console]::Error.WriteLine("${RED}${CB}error:${C0} $m") }
function Fail($m) { Exit-Tui; Write-Err $m; exit 1 }

# ------------------------------------------------------------------ helpers
function Human([double]$b) {
  if ($b -ge 1e9) { return ('{0:0.0} GB' -f ($b / 1e9)) }
  if ($b -ge 1e6) { return ('{0:0.0} MB' -f ($b / 1e6)) }
  if ($b -ge 1e3) { return ('{0:0.0} kB' -f ($b / 1e3)) }
  return ('{0} B' -f [int64]$b)
}
function Eta([int64]$s) {
  if ($s -le 0) { return '--' }
  if ($s -ge 3600) { return ('{0}h {1:00}m' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60)) }
  if ($s -ge 60) { return ('{0}m {1:00}s' -f [math]::Floor($s / 60), ($s % 60)) }
  return "${s}s"
}
function Now { [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
function Rep([string]$c, [int]$n) { if ($n -le 0) { return '' }; return ($c * $n) }
function Is-Admin {
  if (-not $IsWin) { return $true }
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Sha256-File([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }

# ------------------------------------------------------------------ Windows raw disk access
if ($IsWin) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class TomRaw {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool WriteFile(SafeFileHandle h, byte[] buf, int n, out int done, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool ReadFile(SafeFileHandle h, byte[] buf, int n, out int done, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long newp, uint method);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool FlushFileBuffers(SafeFileHandle h);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inb, int insz, IntPtr outb, int outsz, out int ret, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetConsoleMode(IntPtr h, out uint mode);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetConsoleMode(IntPtr h, uint mode);

  public static SafeFileHandle Open(string path, bool write) {
    uint access = write ? 0xC0000000u : 0x80000000u;               // GENERIC_READ (| GENERIC_WRITE)
    uint flags = write ? 0x80000000u : 0u;                          // FILE_FLAG_WRITE_THROUGH
    SafeFileHandle h = CreateFile(path, access, 3, IntPtr.Zero, 3, flags, IntPtr.Zero);
    if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return h;
  }
  public static void Seek(SafeFileHandle h, long pos) {
    long np; if (!SetFilePointerEx(h, pos, out np, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  }
  public static void Write(SafeFileHandle h, byte[] buf, int n) {
    int done; if (!WriteFile(h, buf, n, out done, IntPtr.Zero) || done != n) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  }
  public static int Read(SafeFileHandle h, byte[] buf, int n) {
    int done; if (!ReadFile(h, buf, n, out done, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return done;
  }
  public static void Flush(SafeFileHandle h) { FlushFileBuffers(h); int r; DeviceIoControl(h, 0x70140, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero); }
  public static void EnableVT() {
    IntPtr h = GetStdHandle(-11); uint m;
    if (GetConsoleMode(h, out m)) SetConsoleMode(h, m | 0x0004 | 0x0001);
  }
}
'@
}

# ------------------------------------------------------------------ screen drawing (one buffer per frame)
$script:FB = New-Object System.Text.StringBuilder
$script:W = 78; $script:X = 2
function Cols { try { [Console]::WindowWidth } catch { 100 } }
function Lines { try { [Console]::WindowHeight } catch { 34 } }
function Layout {
  $c = Cols
  $script:W = 78; if ($c -lt 80) { $script:W = $c - 2 }
  $script:X = [math]::Max(1, [int][math]::Floor(($c - $script:W) / 2) + 1)
  [void]$script:FB.Clear(); [void]$script:FB.Append("${E}[H${E}[2J")
}
function Out([string]$s) { [void]$script:FB.Append($s) }
function At([int]$r, [int]$c) { Out "${E}[$r;${c}H" }
function TextAt([int]$r, [int]$c, [string]$s) { At $r ($script:X + $c); Out $s }
function Flush { [Console]::Write($script:FB.ToString()); [void]$script:FB.Clear() }

function Enter-Tui {
  if ($IsWin) { try { [TomRaw]::EnableVT() } catch {} }
  try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
  try { [Console]::TreatControlCAsInput = $true } catch {}
  [Console]::Write("${E}[?1049h${E}[?25l")
  $TS.InTui = $true
}
function Exit-Tui {
  if (-not $TS.InTui) { return }
  [Console]::Write("${C0}${E}[?25h${E}[?1049l")
  try { [Console]::TreatControlCAsInput = $false } catch {}
  $TS.InTui = $false
}

# read one key; returns up/down/left/right/enter/esc/backspace/space/ctrlc/timeout or the character
function Read-Key([double]$timeout = 0) {
  if ($timeout -gt 0) {
    $end = [DateTime]::UtcNow.AddSeconds($timeout)
    while (-not [Console]::KeyAvailable) {
      if ([DateTime]::UtcNow -ge $end) { return 'timeout' }
      Start-Sleep -Milliseconds 40
    }
  }
  $k = [Console]::ReadKey($true)
  if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { return 'ctrlc' }
  switch ($k.Key) {
    'UpArrow' { return 'up' } 'DownArrow' { return 'down' } 'LeftArrow' { return 'left' } 'RightArrow' { return 'right' }
    'Enter' { return 'enter' } 'Escape' { return 'esc' } 'Backspace' { return 'backspace' } 'Spacebar' { return 'space' }
  }
  if ($k.KeyChar -and [int]$k.KeyChar -ge 32) { return [string]$k.KeyChar }
  return 'other'
}
function Drain-Keys { $k = ''; while ([Console]::KeyAvailable) { $k = Read-Key } ; return $k }

function Logo([int]$row) {
  $L = @(
    ' ████████╗ ██████╗ ███╗   ███╗     ██████╗ ███████╗',
    ' ╚══██╔══╝██╔═══██╗████╗ ████║    ██╔═══██╗██╔════╝',
    '    ██║   ██║   ██║██╔████╔██║    ██║   ██║███████╗',
    '    ██║   ██║   ██║██║╚██╔╝██║    ██║   ██║╚════██║',
    '    ██║   ╚██████╔╝██║ ╚═╝ ██║    ╚██████╔╝███████║',
    '    ╚═╝    ╚═════╝ ╚═╝     ╚═╝     ╚═════╝ ╚══════╝'
  )
  $off = $script:X + [int][math]::Floor(($script:W - 52) / 2)
  for ($i = 0; $i -lt 6; $i++) {
    $col = $GRAD[[math]::Min($i * 2, 10)]
    At ($row + $i) $off; Out ("${E}[38;5;${col}m" + $L[$i] + $C0)
  }
  $sub = '//  L I V E   U S B   I N S T A L L E R  //'
  At ($row + 6) ($script:X + [int][math]::Floor(($script:W - $sub.Length) / 2)); Out "$CYAN$CB$sub$C0"
}
function Box([int]$r, [int]$h, [string]$c, [string]$title) {
  $W = $script:W
  At $r $script:X; Out "$c╭─$C0"
  if ($title) { Out "$CB$c $title $C0"; Out ($c + (Rep '─' ($W - $title.Length - 5)) + "╮$C0") }
  else { Out ($c + (Rep '─' ($W - 3)) + "╮$C0") }
  for ($i = 1; $i -lt $h - 1; $i++) { At ($r + $i) $script:X; Out ("$c│$C0" + (' ' * ($W - 2)) + "$c│$C0") }
  At ($r + $h - 1) $script:X; Out ("$c╰" + (Rep '─' ($W - 2)) + "╯$C0")
}
function Footer([string]$t) {
  $l = Lines
  At $l $script:X; Out "$MUTED$t$C0"
  $v = "v$TUI_VERSION"
  if (($t.Length + $v.Length + 2) -le $script:W) { At $l ($script:X + $script:W - $v.Length); Out "$PURPLE$v$C0" }
}
function Bar([int]$w, [double]$done, [double]$total) {
  if ($total -le 0) { $total = 1 }
  $f = [int][math]::Floor($done * $w / $total); if ($f -gt $w) { $f = $w }; if ($f -lt 0) { $f = 0 }
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $f; $i++) { $col = $GRAD[[int][math]::Floor($i * $GRAD.Count / $w)]; [void]$sb.Append("${E}[38;5;${col}m$G_FULL") }
  [void]$sb.Append("${E}[38;5;237m" + (Rep $G_EMPTY ($w - $f)) + $C0)
  return $sb.ToString()
}
function Step([string]$state, [string]$text) {
  switch ($state) {
    'done' { return "$GREEN$G_OK$C0 $text" }
    'now' { return "$PINK$G_SEL$C0 $WHITE$CB$text$C0" }
    default { return "$MUTED$G_MID$C0 $MUTED$text$C0" }
  }
}
function Trunc([string]$s, [int]$n) { if ($s.Length -gt $n) { return $s.Substring(0, $n - 1) + $G_ELL }; return $s }

# ------------------------------------------------------------------ release manifest
function Get-Text([string]$url) {
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromSeconds(20)
  $c.DefaultRequestHeaders.UserAgent.ParseAdd("tomos-installer-tui/$TUI_VERSION")
  try { return $c.GetStringAsync($url).GetAwaiter().GetResult() } finally { $c.Dispose() }
}
function Get-Length([string]$url) {
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromSeconds(20)
  try {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $url)
    $res = $c.SendAsync($req).GetAwaiter().GetResult()
    if ($res.Content.Headers.ContentLength) { return [int64]$res.Content.Headers.ContentLength }
    return [int64]0
  } catch { return [int64]0 } finally { $c.Dispose() }
}
function Fetch-Manifest {
  $TS.ManifestError = ''
  $ver = $env:TOMOS_TUI_VERSION
  if (-not $ver) {
    try { $ver = ((Get-Text $API_LATEST) | ConvertFrom-Json).tag_name -replace '^[vV]', '' } catch { $ver = '' }
    if (-not $ver) { $ver = $DEFAULT_TOMOS_VERSION }
  }
  $name = "tomos-$ver-amd64.iso"
  try {
    $sum = ((Get-Text "$RAW_BASE/$name.sha256") -split "`n" | Where-Object { $_ -match [regex]::Escape($name) } | Select-Object -First 1)
    $parts = (Get-Text "$RAW_BASE/parts.sha256") -split "`n" | Where-Object { $_.Trim() -ne '' }
  } catch { $TS.ManifestError = "could not read the checksums from github.com/$OWNER/$REPO"; return $false }
  if (-not $sum) { $TS.ManifestError = 'no checksum for ' + $name; return $false }
  $list = @()
  foreach ($line in $parts) {
    $f = $line.Trim() -split '\s+'
    if ($f.Count -lt 2) { continue }
    $pn = $f[1].TrimStart('*')
    if ($pn -like "$name.part*") { $list += [pscustomobject]@{ Name = $pn; Sha = $f[0].ToLower(); Num = [int]($pn -replace '.*part', ''); Size = [int64]0 } }
  }
  if ($list.Count -eq 0) { $TS.ManifestError = 'no parts listed for ' + $name; return $false }
  $list = @($list | Sort-Object Num)
  $total = [int64]0
  foreach ($p in $list) { $p.Size = Get-Length "$LFS_BASE/$($p.Name)"; $total += $p.Size }
  $TS.Version = $ver; $TS.IsoName = $name; $TS.RemoteSha = ($sum.Trim() -split '\s+')[0].ToLower()
  $TS.Parts = $list; $TS.TotalSize = $total
  # reuse a verified download
  $iso = Join-Path $DL_DIR $name
  if (-not $TS.IsoPath -and (Is-Verified $iso)) { Use-Iso $iso }
  return $true
}
function Is-Verified([string]$f) {
  if (-not $TS.RemoteSha) { return $false }
  if (-not (Test-Path -LiteralPath $f) -or -not (Test-Path -LiteralPath "$f.verified")) { return $false }
  $want = "$($TS.RemoteSha) $((Get-Item -LiteralPath $f).Length)"
  return ((Get-Content -LiteralPath "$f.verified" -Raw).Trim() -eq $want)
}
function Use-Iso([string]$f) {
  $TS.IsoPath = $f; $TS.IsoSize = (Get-Item -LiteralPath $f).Length; $TS.IsoVerified = $false; $TS.IsoSha = ''
  if (Is-Verified $f) { $TS.IsoVerified = $true; $TS.IsoSha = $TS.RemoteSha }
}

# ------------------------------------------------------------------ drives
# Each drive: Dev (disk number), Path (\\.\PhysicalDriveN), Size, Name, Removable, System, ReadOnly, Mounts, Sector
function Get-Drives {
  $out = @()
  if ($env:TOMOS_TUI_FAKE_DRIVES) {
    foreach ($l in ($env:TOMOS_TUI_FAKE_DRIVES -split ';')) {
      $f = $l -split '\|'
      if ($f.Count -lt 7) { continue }
      $path = $f[0]; if ($f[0] -match '^\d+$') { $path = "\\.\PhysicalDrive$($f[0])" }
      $out += [pscustomobject]@{ Dev = $f[0]; Path = $path; Size = [int64]$f[1]; Name = $f[2]; Removable = ($f[3] -eq '1'); System = ($f[4] -eq '1'); ReadOnly = ($f[5] -eq '1'); Mounts = $f[6].Trim(); Sector = 512; Bus = 'USB' }
    }
    return $out
  }
  if (-not $IsWin) { return $out }
  $sysLetter = ($env:SystemDrive).TrimEnd(':')
  $allow = @(); if ($env:TOMOS_TUI_ALLOW_DEVICE) { $allow = @($env:TOMOS_TUI_ALLOW_DEVICE -split '[ ,;]' | ForEach-Object { $_ -replace '\D', '' } | Where-Object { $_ }) }
  try { $disks = @(Get-Disk -ErrorAction Stop | Sort-Object Number) }
  catch { $TS.Message = "Can't list disks: $($_.Exception.Message)"; $TS.Kind = 'err'; return $out }
  foreach ($d in $disks) {
    $letters = @()
    try { $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and [string]$_.DriveLetter -ne "`0" } | ForEach-Object { "$($_.DriveLetter):" }) } catch {}
    $system = [bool]($d.IsBoot -or $d.IsSystem) -or ($letters -contains "${sysLetter}:")
    $bus = [string]$d.BusType
    $rem = ($bus -eq 'USB' -or $bus -eq 'SD' -or $bus -eq 'MMC') -or ($allow -contains [string]$d.Number)
    $sector = 512; if ($d.LogicalSectorSize) { $sector = [int]$d.LogicalSectorSize }
    $name = [string]$d.FriendlyName; if (-not $name) { $name = "Disk $($d.Number)" }
    $out += [pscustomobject]@{ Dev = [string]$d.Number; Path = "\\.\PhysicalDrive$($d.Number)"; Size = [int64]$d.Size; Name = $name.Trim()
      Removable = [bool]$rem; System = $system; ReadOnly = [bool]$d.IsReadOnly; Mounts = ($letters -join ' '); Sector = $sector; Bus = $bus }
  }
  return $out
}
function Visible-Drives {
  $d = @(Get-Drives)
  if ($TS.ShowAll) { return $d }
  return @($d | Where-Object { $_.Removable -and -not $_.System -and -not $_.ReadOnly })
}
function Find-Drive([string]$spec) {
  $n = $spec -replace '^\\\\\.\\', '' -replace '(?i)^physicaldrive', '' -replace '(?i)^disk', ''
  return (Get-Drives | Where-Object { $_.Dev -eq $n } | Select-Object -First 1)
}
function Drive-Label($d) { return "Disk $($d.Dev)" }

# ------------------------------------------------------------------ progress screen
function Progress-Screen([string]$title, [string]$sub, [double]$done, [double]$total, [int64]$started, [string[]]$steps) {
  Layout; Logo 2
  $r = 11
  $n = 0; if ($steps) { $n = $steps.Count }
  $h = 10; if ($n -gt 3) { $h = $n + 7 }
  Box $r $h $CYAN $title
  TextAt ($r + 1) 3 ($MUTED + (Trunc $sub ($script:W - 6)) + $C0)
  $pct = 0.0; if ($total -gt 0) { $pct = $done * 100 / $total }
  At ($r + 3) ($script:X + 3); Out (Bar ($script:W - 16) $done $total); Out ('  {0}{1}{2,5:0.0}%{3}' -f $WHITE, $CB, $pct, $C0)
  $el = (Now) - $started; if ($el -lt 1) { $el = 1 }
  $speed = [int64]($done / $el); $left = 0; if ($speed -gt 0) { $left = [int64](($total - $done) / $speed) }
  TextAt ($r + 4) 3 ("$WHITE$(Human $done)$C0 ${MUTED}of $(Human $total)   $G_MID   $(Human $speed)/s   $G_MID   $(Eta $left) left$C0")
  for ($i = 0; $i -lt $n; $i++) { TextAt ($r + 6 + $i) 3 $steps[$i] }
  Footer 'Esc or Ctrl+C cancels'
  Flush
}
function Cancel-Requested {
  while ([Console]::KeyAvailable) { $k = Read-Key; if ($k -eq 'esc' -or $k -eq 'ctrlc') { return $true } }
  return $false
}
function Cli-Progress([double]$done, [double]$total) {
  [Console]::Error.Write("`r  " + (Bar 30 $done $total) + " $(Human $done) / $(Human $total)   ")
}

# ------------------------------------------------------------------ download (resumable, every part checked)
function Download-Part($p, [string]$file, [scriptblock]$onProgress) {
  $have = [int64]0; if (Test-Path -LiteralPath $file) { $have = (Get-Item -LiteralPath $file).Length }
  if ($p.Size -gt 0 -and $have -eq $p.Size) { return 'ok' }
  if ($p.Size -gt 0 -and $have -gt $p.Size) { Remove-Item -LiteralPath $file -Force; $have = 0 }
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromHours(6)
  $c.DefaultRequestHeaders.UserAgent.ParseAdd("tomos-installer-tui/$TUI_VERSION")
  try {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "$LFS_BASE/$($p.Name)")
    if ($have -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($have, $null) }
    $res = $c.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $res.IsSuccessStatusCode) { return "HTTP $([int]$res.StatusCode)" }
    $mode = [IO.FileMode]::Append
    if ($have -gt 0 -and [int]$res.StatusCode -ne 206) { $mode = [IO.FileMode]::Create; $have = 0 }
    $in = $res.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $fs = New-Object IO.FileStream($file, $mode, [IO.FileAccess]::Write)
    try {
      $buf = New-Object byte[] 1048576
      $last = [DateTime]::MinValue
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n); $have += $n
        if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 400) {
          $last = [DateTime]::UtcNow
          if (& $onProgress $have) { return 'cancel' }
        }
      }
    } finally { $fs.Close(); $in.Close() }
    & $onProgress $have | Out-Null
    return 'ok'
  } catch { return $_.Exception.Message } finally { $c.Dispose() }
}

function Do-Download([bool]$cli = $false) {
  if (-not $TS.Version) { if (-not (Fetch-Manifest)) { $TS.Message = "Can't reach GitHub: $($TS.ManifestError)"; $TS.Kind = 'err'; return $false } }
  New-Item -ItemType Directory -Force -Path $DL_DIR | Out-Null
  $iso = Join-Path $DL_DIR $TS.IsoName
  if (Is-Verified $iso) { Use-Iso $iso; $TS.Message = "Already downloaded and verified: $iso"; $TS.Kind = 'ok'; return $true }
  try {
    $drv = (Get-Item -LiteralPath $DL_DIR).PSDrive
    if ($drv -and $drv.Free -and $drv.Free -lt ($TS.TotalSize + 1100000000)) {
      $TS.Message = "Not enough free space in ${DL_DIR}: need $(Human ($TS.TotalSize + 1100000000)), have $(Human $drv.Free)"; $TS.Kind = 'err'; return $false
    }
  } catch {}
  $started = Now; $parts = $TS.Parts; $n = $parts.Count
  $offset = [int64]0
  for ($i = 0; $i -lt $n; $i++) {
    $p = $parts[$i]; $file = Join-Path $DL_DIR ".$($p.Name)"
    if ((Test-Path -LiteralPath "$file.ok") -and (Test-Path -LiteralPath $file) -and ((Get-Content -LiteralPath "$file.ok" -Raw).Trim() -eq $p.Sha)) { $offset += $p.Size; continue }
    if ($cli) { [Console]::Error.WriteLine("${PINK}${CB}==>${C0} Part $($i + 1) of ${n}: $($p.Name)") }
    $steps = @(); for ($j = 0; $j -lt $n; $j++) { $st = 'todo'; if ($j -lt $i) { $st = 'done' }; if ($j -eq $i) { $st = 'now' }; $steps += (Step $st "Part $($j + 1) of $n  $($parts[$j].Name)") }
    $base = $offset
    $onProgress = {
      param($got)
      if ($cli) { Cli-Progress ($base + $got) $TS.TotalSize; return $false }
      Progress-Screen "DOWNLOADING TOM OS $($TS.Version)" "from github.com/$OWNER/$REPO  ->  $DL_DIR" ($base + $got) $TS.TotalSize $started $steps
      return (Cancel-Requested)
    }
    $res = Download-Part $p $file $onProgress
    if ($cli) { [Console]::Error.WriteLine('') }
    if ($res -eq 'cancel') { $TS.Message = 'Download paused - choose Download again to resume'; $TS.Kind = 'warn'; return $false }
    if ($res -ne 'ok') { $TS.Message = "Download failed ($res). Check your connection and choose Download to resume."; $TS.Kind = 'err'; return $false }
    if (-not $cli) { Progress-Screen "DOWNLOADING TOM OS $($TS.Version)" "Checking part $($i + 1) of $n$G_ELL" ($offset + $p.Size) $TS.TotalSize $started $steps }
    if ((Sha256-File $file) -ne $p.Sha) {
      Remove-Item -LiteralPath $file -Force
      $TS.Message = "Part $($i + 1) failed its SHA-256 check and was deleted - choose Download to try again"; $TS.Kind = 'err'; return $false
    }
    Set-Content -LiteralPath "$file.ok" -Value $p.Sha
    $offset += $p.Size
  }
  # join the parts and hash the result in one pass
  if ($cli) { [Console]::Error.WriteLine("${PINK}${CB}==>${C0} Joining and verifying the whole image$G_ELL") }
  $tmp = "$iso.download"
  $sha = [Security.Cryptography.SHA256]::Create()
  $outf = New-Object IO.FileStream($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write)
  $buf = New-Object byte[] $BS; $done = [int64]0; $last = [DateTime]::MinValue; $t0 = Now
  $steps = @((Step 'done' 'Downloaded every part'), (Step 'now' 'Joining and checking the whole image'))
  try {
    foreach ($p in $parts) {
      $inf = [IO.File]::OpenRead((Join-Path $DL_DIR ".$($p.Name)"))
      try {
        while (($k = $inf.Read($buf, 0, $buf.Length)) -gt 0) {
          $outf.Write($buf, 0, $k); [void]$sha.TransformBlock($buf, 0, $k, $null, 0); $done += $k
          if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 400) {
            $last = [DateTime]::UtcNow
            if ($cli) { Cli-Progress $done $TS.TotalSize } else { Progress-Screen 'VERIFYING THE DOWNLOAD' "SHA-256 of $($TS.IsoName)" $done $TS.TotalSize $t0 $steps }
          }
        }
      } finally { $inf.Close() }
    }
    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
  } finally { $outf.Close() }
  if ($cli) { Cli-Progress $done $TS.TotalSize; [Console]::Error.WriteLine('') }
  $whole = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
  if ($whole -ne $TS.RemoteSha) {
    Remove-Item -LiteralPath $tmp -Force
    $TS.Message = 'The joined image does not match the published SHA-256. Choose Download to try again.'; $TS.Kind = 'err'; return $false
  }
  Move-Item -LiteralPath $tmp -Destination $iso -Force
  Set-Content -LiteralPath "$iso.verified" -Value "$($TS.RemoteSha) $((Get-Item -LiteralPath $iso).Length)"
  foreach ($p in $parts) { $f = Join-Path $DL_DIR ".$($p.Name)"; Remove-Item -LiteralPath $f, "$f.ok" -Force -ErrorAction SilentlyContinue }
  Use-Iso $iso
  $TS.Message = "Downloaded and verified Tom OS $($TS.Version) -> $iso"; $TS.Kind = 'ok'
  return $true
}

# ------------------------------------------------------------------ burning
# Steps: wipe the partition table with diskpart (Windows drops the old volumes), write
# everything except the first 4 MiB, then the first 4 MiB last - so Windows never sees
# a partition table half way and never mounts the stick while we write. Then read back.
function Burn-Core($drive, [string]$iso, [bool]$cli) {
  $size = (Get-Item -LiteralPath $iso).Length
  $sector = [math]::Max(512, [int]$drive.Sector)
  $label = "$($drive.Name) $G_MID $(Drive-Label $drive)"
  $mk = {
    param($a, $b, $c, $d)
    $v = Step $c 'Read back and verify'; if (-not $TS.Verify) { $v = Step 'skip' 'Verify (off)' }
    return @((Step $a "Clean $(Drive-Label $drive)"), (Step $b "Write $(Split-Path $iso -Leaf)"), $v, (Step $d 'Finish'))
  }
  $say = { param($m) if ($cli) { [Console]::Error.WriteLine("${PINK}${CB}==>${C0} $m") } }

  # 1. clean
  & $say "Cleaning $(Drive-Label $drive)"
  if (-not $cli) { Progress-Screen 'BURNING TOM OS' $label 0 $size (Now) (& $mk 'now' 'todo' 'todo' 'todo') }
  if (-not $env:TOMOS_TUI_FAKE_DRIVES) {
    $script = Join-Path $env:TEMP "tomos-diskpart-$PID.txt"
    Set-Content -LiteralPath $script -Value "select disk $($drive.Dev)`r`nattributes disk clear readonly noerr`r`nclean`r`nrescan`r`n" -Encoding ASCII
    $dp = & diskpart.exe /s $script 2>&1 | Out-String
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { return "diskpart could not clean the drive: $(($dp -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim())" }
    Start-Sleep -Milliseconds 800
  }

  # 2. write
  & $say "Writing $(Split-Path $iso -Leaf)"
  $steps = & $mk 'done' 'now' 'todo' 'todo'
  $started = Now; $done = [int64]0; $last = [DateTime]::MinValue
  $buf = New-Object byte[] $BS; $first = New-Object byte[] $BS; $firstLen = 0
  $h = $null; $inf = $null
  try {
    if ($env:TOMOS_TUI_FAKE_DRIVES) { $fs = [IO.File]::Open($drive.Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite) }
    else { $h = [TomRaw]::Open($drive.Path, $true) }
    $inf = [IO.File]::OpenRead($iso)
    $pos = [int64]0
    while ($true) {
      $k = 0; while ($k -lt $BS) { $r = $inf.Read($buf, $k, $BS - $k); if ($r -le 0) { break }; $k += $r }
      if ($k -le 0) { break }
      $len = $k; if ($len % $sector) { [Array]::Clear($buf, $len, $BS - $len); $len = $len + $sector - ($len % $sector) }
      if ($pos -eq 0) { [Array]::Copy($buf, $first, $BS); $firstLen = $len }
      else {
        if ($h) { [TomRaw]::Seek($h, $pos); [TomRaw]::Write($h, $buf, $len) } else { $fs.Seek($pos, 'Begin') | Out-Null; $fs.Write($buf, 0, $len) }
      }
      $pos += $k; $done = $pos
      if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 400) {
        $last = [DateTime]::UtcNow
        if ($cli) { Cli-Progress $done $size } else { Progress-Screen 'BURNING TOM OS' $label $done $size $started $steps; if (Cancel-Requested) { return 'Cancelled. The stick is incomplete and will not boot.' } }
      }
    }
    if ($firstLen -gt 0) { if ($h) { [TomRaw]::Seek($h, 0); [TomRaw]::Write($h, $first, $firstLen) } else { $fs.Seek(0, 'Begin') | Out-Null; $fs.Write($first, 0, $firstLen) } }
    if ($h) { [TomRaw]::Flush($h) } else { $fs.Flush() }
  } catch {
    return "Writing failed: $($_.Exception.Message)"
  } finally {
    if ($inf) { $inf.Close() }
    if ($h) { $h.Close() }
    if ($fs) { $fs.Close() }
  }
  if ($cli) { Cli-Progress $size $size; [Console]::Error.WriteLine('') }

  # 3. verify
  if ($TS.Verify) {
    $steps = & $mk 'done' 'done' 'now' 'todo'
    if (-not $TS.IsoSha) {
      & $say 'Hashing the image'
      if (-not $cli) { Progress-Screen 'CHECKING THE IMAGE' "SHA-256 of $(Split-Path $iso -Leaf) (needed to verify the stick)" 0 $size (Now) $steps }
      $TS.IsoSha = Sha256-File $iso
    }
    & $say 'Verifying the stick'
    $sha = [Security.Cryptography.SHA256]::Create()
    $started = Now; $done = [int64]0; $last = [DateTime]::MinValue
    try {
      if ($env:TOMOS_TUI_FAKE_DRIVES) { $fs = [IO.File]::OpenRead($drive.Path); $h = $null } else { $h = [TomRaw]::Open($drive.Path, $false); $fs = $null }
      while ($done -lt $size) {
        $want = [int64]$BS; if ($size - $done -lt $want) { $want = $size - $done; if ($want % $sector) { $want = $want + $sector - ($want % $sector) } }
        if ($h) { $k = [TomRaw]::Read($h, $buf, [int]$want) } else { $k = $fs.Read($buf, 0, [int]$want) }
        if ($k -le 0) { break }
        $use = [int][math]::Min([int64]$k, $size - $done)
        [void]$sha.TransformBlock($buf, 0, $use, $null, 0); $done += $use
        if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 400) {
          $last = [DateTime]::UtcNow
          if ($cli) { Cli-Progress $done $size } else { Progress-Screen 'VERIFYING THE USB STICK' $label $done $size $started $steps; if (Cancel-Requested) { return 'Verification cancelled. The stick was written but not checked.' } }
        }
      }
      [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    } catch { return "Reading the stick back failed: $($_.Exception.Message)" }
    finally { if ($h) { $h.Close() }; if ($fs) { $fs.Close() } }
    if ($cli) { Cli-Progress $size $size; [Console]::Error.WriteLine('') }
    $got = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
    if ($got -ne $TS.IsoSha) { return 'Verification failed: the stick does not match the image. It may be faulty or fake - try another one.' }
    if ($cli) { [Console]::Error.WriteLine('    every byte matches') }
  }
  # 4. finish
  if (-not $cli) { Progress-Screen 'BURNING TOM OS' "Finishing$G_ELL" $size $size (Now) (& $mk 'done' 'done' 'done' 'now') }
  if (-not $env:TOMOS_TUI_FAKE_DRIVES) { try { Update-Disk -Number ([int]$drive.Dev) -ErrorAction SilentlyContinue } catch {} }
  return 'ok'
}

function Burn-Tui {
  $d = $TS.Drive
  if (-not (Is-Admin)) {
    # writing to a whole disk needs Administrator: run just the burn in an elevated window
    Layout; Logo 2; Box 10 6 $YELLOW 'ADMINISTRATOR NEEDED'
    TextAt 12 3 "${WHITE}Windows will ask for permission (UAC) to write to $(Drive-Label $d).$C0"
    TextAt 13 3 "${MUTED}The burn runs in a new window; come back here when it's finished.$C0"
    Footer 'Waiting for the burn window'; Flush
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '--burn-tui', $d.Dev, '--iso', "`"$($TS.IsoPath)`"")
    if (-not $TS.Verify) { $args2 += '--no-verify' }
    if ($TS.IsoSha) { $args2 += @('--sha', $TS.IsoSha) }
    $exe = (Get-Process -Id $PID).Path
    try { $p = Start-Process -FilePath $exe -ArgumentList $args2 -Verb RunAs -Wait -PassThru }
    catch { $TS.Message = 'Permission was not given - nothing was written'; $TS.Kind = 'warn'; return }
    if ($p.ExitCode -eq 0) { $TS.Message = "Tom OS was written to $($d.Name) ($(Drive-Label $d))"; $TS.Kind = 'ok'; $TS.Drive = $null }
    else { $TS.Message = 'The burn did not finish - see the burn window for details'; $TS.Kind = 'err' }
    return
  }
  $res = Burn-Core $d $TS.IsoPath $false
  if ($res -eq 'ok') { Done-Screen; return $true }
  Burn-Failed $res; return $false
}
function Burn-Failed([string]$m) {
  $TS.Message = $m; $TS.Kind = 'err'
  Layout; Logo 2; Box 10 8 $RED 'SOMETHING WENT WRONG'
  $w = $script:W - 6
  TextAt 12 3 ($WHITE + $m.Substring(0, [math]::Min($m.Length, $w)) + $C0)
  if ($m.Length -gt $w) { TextAt 13 3 ($WHITE + (Trunc $m.Substring($w) $w) + $C0) }
  TextAt 15 3 "${MUTED}The stick is probably incomplete and won't boot. Fix the problem and burn again.$C0"
  Footer 'Press any key to go back'; Flush
  Drain-Keys | Out-Null; Read-Key | Out-Null
}
function Done-Screen {
  $d = $TS.Drive
  $TS.Message = "Tom OS was written to $($d.Name) ($(Drive-Label $d))"; $TS.Kind = 'ok'
  Layout; Logo 2
  $r = 10; Box $r 10 $GREEN "$G_OK  TOM OS IS READY"
  $v = $TS.Version; if (-not $v) { $v = '' }
  TextAt ($r + 2) 3 "$WHITE${CB}Tom OS $v$C0 is on $CYAN$($d.Name)$C0 $MUTED($(Drive-Label $d))$C0"
  if ($TS.Verify) { TextAt ($r + 3) 3 "${GREEN}Every byte was read back and matches the image.$C0" }
  TextAt ($r + 5) 3 "${PINK}Next:$C0 restart with the stick plugged in and open the boot menu"
  TextAt ($r + 6) 3 "      $MUTED(F12, F11, F8 or Esc on most PCs; Secure Boot may need to be off).$C0"
  TextAt ($r + 7) 3 "      Pick the USB stick, then ${CYAN}Install Tom OS$C0 from the desktop."
  Footer 'Press any key to go back to the menu'; Flush
  $TS.Drive = $null
  Drain-Keys | Out-Null; Read-Key | Out-Null
}

# ------------------------------------------------------------------ screens
function Status-Card([int]$r) {
  Box $r 5 $PURPLE 'STATUS'
  if ($TS.IsoPath) {
    $tag = "${YELLOW}local file$C0"; if ($TS.IsoVerified) { $tag = "$GREEN$G_OK SHA-256 verified$C0" }
    TextAt ($r + 1) 3 "${MUTED}IMAGE $C0 $WHITE$(Trunc (Split-Path $TS.IsoPath -Leaf) 34)$C0  $MUTED$(Human $TS.IsoSize)$C0  $tag"
  } else { TextAt ($r + 1) 3 "${MUTED}IMAGE $C0 ${DIM}not chosen yet$C0" }
  if ($TS.Drive) { TextAt ($r + 2) 3 "${MUTED}DRIVE $C0 $WHITE$(Trunc $TS.Drive.Name 34)$C0  $MUTED$(Human $TS.Drive.Size) $G_MID $(Drive-Label $TS.Drive)$C0" }
  else { TextAt ($r + 2) 3 "${MUTED}DRIVE $C0 ${DIM}not chosen yet$C0" }
  $v = 'on'; if (-not $TS.Verify) { $v = 'off' }
  $rel = "checking GitHub$G_ELL"
  if ($TS.Version) { $rel = "Tom OS $($TS.Version) $G_MID $(Human $TS.TotalSize)" }
  if ($TS.ManifestError) { $rel = "${YELLOW}offline$C0" }
  TextAt ($r + 3) 3 "${MUTED}LATEST$C0 $CYAN$rel$C0   ${MUTED}VERIFY$C0 $v"
}
function Message-Line([int]$r) {
  if (-not $TS.Message) { return }
  $c = $CYAN; switch ($TS.Kind) { 'err' { $c = $RED } 'ok' { $c = $GREEN } 'warn' { $c = $YELLOW } }
  TextAt $r 1 "$c$G_DOT $(Trunc $TS.Message ($script:W - 4))$C0"
}

function Menu-Screen {
  $sel = 0; $first = $true
  while ($true) {
    $dl = 'Download Tom OS'
    if ($TS.Version) { $dl = "Download Tom OS $($TS.Version)  $MUTED($(Human $TS.TotalSize), verified)$C0" }
    if ($TS.IsoPath -and $TS.IsoVerified -and (Split-Path $TS.IsoPath -Leaf) -eq $TS.IsoName) { $dl = "Download Tom OS $($TS.Version)  $GREEN$G_OK done$C0" }
    $burn = 'Burn Tom OS to the USB drive'
    if (-not $TS.IsoPath -or -not $TS.Drive) { $burn = "${MUTED}Burn Tom OS to the USB drive  (choose an image and a drive first)$C0" }
    $ver = "Verify after burning: ${GREEN}on$C0"; if (-not $TS.Verify) { $ver = "Verify after burning: ${YELLOW}off$C0" }
    $items = @($dl, 'Use an ISO file already on this computer', 'Choose the USB drive', $burn, $ver, 'Help', 'Quit')
    $n = $items.Count
    Layout; Logo 2; Status-Card 10
    $r = 16; Box $r ($n + 2) $PINK 'MENU'
    for ($i = 0; $i -lt $n; $i++) {
      if ($i -eq $sel) { At ($r + 1 + $i) ($script:X + 2); Out "$BGSEL$PINK$CB $G_SEL $C0$BGSEL$WHITE$CB$($items[$i])$C0" }
      else { TextAt ($r + 1 + $i) 3 "   $($items[$i])" }
    }
    Message-Line ($r + $n + 3)
    Footer "Up/Down move   Enter select   d download   f file   u drive   b burn   q quit"
    Flush
    if ($first -and -not $TS.Version -and -not $TS.ManifestError -and -not $env:TOMOS_TUI_DEMO) { $first = $false; Fetch-Manifest | Out-Null; continue }
    $k = Read-Key 3
    switch -CaseSensitive ($k) {
      'up' { $sel = ($sel + $n - 1) % $n } 'k' { $sel = ($sel + $n - 1) % $n }
      'down' { $sel = ($sel + 1) % $n } 'j' { $sel = ($sel + 1) % $n }
      'd' { $sel = 0; $k = 'enter' } 'f' { $sel = 1; $k = 'enter' } 'u' { $sel = 2; $k = 'enter' } 'b' { $sel = 3; $k = 'enter' }
      'q' { return } 'Q' { return } 'ctrlc' { return }
    }
    if ($k -eq 'enter') {
      $TS.Message = ''
      switch ($sel) {
        0 { Do-Download | Out-Null }
        1 { File-Screen }
        2 { Drive-Screen }
        3 {
          if (-not $TS.IsoPath) { $TS.Message = 'Choose an image first (Download, or use an ISO file)'; $TS.Kind = 'warn' }
          elseif (-not $TS.Drive) { $TS.Message = 'Choose the USB drive first'; $TS.Kind = 'warn' }
          elseif (Confirm-Screen) { Burn-Tui | Out-Null }
        }
        4 { $TS.Verify = -not $TS.Verify }
        5 { Help-Screen }
        6 { return }
      }
    }
  }
}

function File-Screen {
  $found = New-Object System.Collections.ArrayList
  $home2 = [Environment]::GetFolderPath('UserProfile')
  foreach ($d in @($DL_DIR, (Join-Path $home2 'Downloads'), (Join-Path $home2 'Desktop'), (Get-Location).Path)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.iso' })) {
      if (-not $found.Contains($f.FullName)) { [void]$found.Add($f.FullName) }
    }
  }
  $sel = 0; $typed = ''; $mode = 'list'
  while ($true) {
    $n = $found.Count
    Layout; Logo 2
    $r = 10; $rows = [math]::Max($n, 1)
    Box $r ($rows + 6) $PINK 'USE AN ISO FILE'
    TextAt ($r + 1) 3 "${MUTED}ISO files found in Downloads, Desktop and here:$C0"
    if ($n -eq 0) { TextAt ($r + 3) 3 "${DIM}none found$C0" }
    for ($i = 0; $i -lt $n; $i++) {
      $x = $found[$i]; $s = Human (Get-Item -LiteralPath $x).Length
      if ($x.Length -gt $script:W - 20) { $x = $G_ELL + $x.Substring($x.Length - ($script:W - 22)) }
      if ($mode -eq 'list' -and $i -eq $sel) { TextAt ($r + 3 + $i) 2 "$BGSEL$PINK$CB $G_SEL $C0$BGSEL$WHITE$x  $MUTED$s$C0" }
      else { TextAt ($r + 3 + $i) 2 "   $x  $MUTED$s$C0" }
    }
    $pr = $r + 3 + $rows + 1
    if ($mode -eq 'type') { TextAt $pr 3 "${CYAN}Path:$C0 $WHITE$typed$PINK$G_CUR$C0" }
    else { TextAt $pr 3 "${MUTED}Press$C0 ${CYAN}t$C0 ${MUTED}to type a path$C0" }
    Footer 'Up/Down move   Enter choose   t type a path   Esc back'; Flush
    $k = Read-Key
    if ($mode -eq 'type') {
      switch ($k) {
        'enter' {
          $p = $typed.Trim('"')
          if (Test-Path -LiteralPath $p -PathType Leaf) { Choose-Iso (Resolve-Path -LiteralPath $p).Path } else { $TS.Message = "No such file: $p"; $TS.Kind = 'err' }
          return
        }
        'esc' { $mode = 'list' }
        'backspace' { if ($typed.Length) { $typed = $typed.Substring(0, $typed.Length - 1) } }
        'space' { $typed += ' ' }
        { $_ -in 'up', 'down', 'left', 'right', 'timeout', 'other', 'ctrlc' } { }
        default { $typed += $k }
      }
      continue
    }
    switch ($k) {
      'up' { if ($n) { $sel = ($sel + $n - 1) % $n } }
      'down' { if ($n) { $sel = ($sel + 1) % $n } }
      't' { $mode = 'type' }
      'enter' { if ($n) { Choose-Iso $found[$sel]; return } }
      'esc' { return } 'q' { return }
    }
  }
}
function Choose-Iso([string]$f) {
  Use-Iso $f
  $TS.Message = "Image: $(Split-Path $f -Leaf)"; $TS.Kind = 'ok'
  if ($TS.IsoSize -lt 100000000) { $TS.Message = "That file is only $(Human $TS.IsoSize) - is it really an ISO?"; $TS.Kind = 'warn' }
}

function Drive-Screen {
  $sel = 0
  while ($true) {
    $list = @(Visible-Drives); $n = $list.Count
    if ($sel -ge $n) { $sel = 0 }
    Layout; Logo 2
    $r = 10; $h = 7; if ($n -gt 0) { $h = $n * 2 + 4 }
    Box $r $h $CYAN 'CHOOSE THE USB DRIVE'
    if ($n -eq 0) {
      TextAt ($r + 2) 3 "$CYAN$G_USB$C0  $WHITE${CB}Plug in a USB stick$C0 $MUTED(8 GB or bigger) $G_DASH it shows up here automatically$C0"
      if (-not $TS.ShowAll) { TextAt ($r + 3) 6 "${MUTED}Press$C0 ${CYAN}a$C0 ${MUTED}to show every disk$C0" }
    }
    for ($i = 0; $i -lt $n; $i++) {
      $d = $list[$i]
      $sub = "$(Human $d.Size) $G_MID $(Drive-Label $d)"; $col = $WHITE
      if ($d.System) { $sub = "$RED$G_NO system disk $G_DASH protected$C0"; $col = $MUTED }
      elseif ($d.ReadOnly) { $sub = "${RED}write protected$C0"; $col = $MUTED }
      elseif (-not $d.Removable) { $sub += " $YELLOW$G_MID internal disk $G_DASH locked$C0"; $col = $MUTED }
      if ($d.Mounts -and -not $d.System) { $sub += " $MUTED$G_MID $($d.Mounts)$C0" }
      $icon = $G_USB; if (-not $d.Removable) { $icon = $G_DISK }
      $mark = '  '; if ($TS.Drive -and $TS.Drive.Dev -eq $d.Dev) { $mark = "$CYAN$G_OK$C0 " }
      if ($i -eq $sel) { TextAt ($r + 2 + $i * 2) 2 "$BGSEL$PINK$CB $G_SEL $icon $C0$BGSEL$col$CB$(Trunc $d.Name 50)$C0 $mark" }
      else { TextAt ($r + 2 + $i * 2) 2 "   $PURPLE$icon$C0 $col$(Trunc $d.Name 50)$C0 $mark" }
      TextAt ($r + 3 + $i * 2) 8 "$MUTED$sub$C0"
    }
    $all = 'show all disks'; if ($TS.ShowAll) { $all = 'USB only' }
    Footer "Up/Down move   Enter choose   r refresh   a $all   Esc back"; Flush
    $k = Read-Key 3
    switch ($k) {
      'up' { if ($n) { $sel = ($sel + $n - 1) % $n } }
      'down' { if ($n) { $sel = ($sel + 1) % $n } }
      'a' { $TS.ShowAll = -not $TS.ShowAll; $sel = 0 }
      'esc' { return } 'q' { return }
      'enter' {
        if (-not $n) { break }
        $d = $list[$sel]
        if ($d.System -or $d.ReadOnly -or -not $d.Removable -or $d.Size -le 0) { $TS.Message = "That disk is locked (Windows, internal or write protected) - see Help"; $TS.Kind = 'err'; break }
        $TS.Drive = $d; $TS.Message = "Drive: $($d.Name) ($(Drive-Label $d))"; $TS.Kind = 'ok'
        if ($TS.IsoPath -and $d.Size -lt $TS.IsoSize) { $TS.Message = "$($d.Name) is too small ($(Human $d.Size)) for $(Human $TS.IsoSize)"; $TS.Kind = 'err'; $TS.Drive = $null }
        return
      }
    }
  }
}

function Confirm-Screen {
  $d = $TS.Drive; $want = "disk$($d.Dev)"; $typed = ''
  while ($true) {
    Layout; Logo 2
    $r = 10; Box $r 11 $RED '!  ERASE THIS DRIVE?'
    TextAt ($r + 2) 3 "$WHITE$CB$($d.Name)$C0  $MUTED$(Human $d.Size) $G_MID $(Drive-Label $d)$C0"
    if (-not $d.Removable) { TextAt ($r + 3) 3 "$RED${CB}This is NOT a removable drive. Check twice.$C0" }
    TextAt ($r + 4) 3 "Everything on it will be $RED${CB}permanently deleted$C0 and replaced with"
    TextAt ($r + 5) 3 "$CYAN$(Split-Path $TS.IsoPath -Leaf)$C0 $MUTED($(Human $TS.IsoSize))$C0."
    TextAt ($r + 7) 3 "Type $YELLOW$CB$want$C0 and press Enter to continue:  $WHITE$typed$PINK$G_CUR$C0"
    $note = 'Windows will ask for Administrator permission to write to the drive.'
    if (Is-Admin) { $note = 'Running as Administrator.' }
    TextAt ($r + 8) 3 "$MUTED$note$C0"
    Footer 'Type the drive name to confirm   Esc cancel'; Flush
    $k = Read-Key
    switch ($k) {
      'esc' { $TS.Message = 'Cancelled - nothing was written'; $TS.Kind = 'warn'; return $false }
      'ctrlc' { $TS.Message = 'Cancelled - nothing was written'; $TS.Kind = 'warn'; return $false }
      'enter' { if ($typed.ToLower() -eq $want) { return $true }; $typed = '' }
      'backspace' { if ($typed.Length) { $typed = $typed.Substring(0, $typed.Length - 1) } }
      { $_ -in 'up', 'down', 'left', 'right', 'space', 'timeout', 'other' } { }
      default { $typed += $k }
    }
  }
}

function Help-Screen {
  Layout; Logo 2
  $r = 10; Box $r 13 $PURPLE 'HELP'
  TextAt ($r + 1) 3 "$WHITE${CB}1.$C0 ${CYAN}Download$C0 gets the latest Tom OS from github.com/$OWNER/$REPO"
  TextAt ($r + 2) 3 '   in parts, checks each part and the whole ISO with SHA-256 and keeps it in'
  TextAt ($r + 3) 3 "   $MUTED$(Trunc $DL_DIR 44)$C0. Press Esc while downloading to pause."
  TextAt ($r + 4) 3 "$WHITE${CB}2.$C0 ${CYAN}Choose the USB drive$C0. Only USB and SD drives are listed; the Windows"
  TextAt ($r + 5) 3 "   disk and internal disks are locked. Press ${CYAN}a$C0 to see every disk."
  TextAt ($r + 6) 3 "$WHITE${CB}3.$C0 ${CYAN}Burn${C0}: type the drive name to confirm and allow Administrator access."
  TextAt ($r + 7) 3 '   The stick is wiped, written sector by sector and read back to verify.'
  TextAt ($r + 9) 3 "${PINK}Boot it:$C0 restart and press F12, F11, F8 or Esc for the boot menu."
  TextAt ($r + 10) 3 "${MUTED}Tom OS is for 64-bit PCs (x86_64). Secure Boot may need to be off.$C0"
  TextAt ($r + 11) 3 "${MUTED}Command line: tomos-installer-tui --help$C0"
  Footer 'Press any key to go back'; Flush
  Read-Key | Out-Null
}

# ------------------------------------------------------------------ command line
function Usage {
  @"
$PINK${CB}Tom OS Installer TUI$C0 $TUI_VERSION (Windows) - download Tom OS and burn it to a USB stick

${CB}USAGE$C0
  tomos-installer-tui                     open the full-screen app
  tomos-installer-tui --list [--all]      list USB drives
  tomos-installer-tui --info              show the latest Tom OS release
  tomos-installer-tui --download          download + verify the ISO into $DL_DIR
  tomos-installer-tui --burn DISK [--iso FILE] [--no-verify] [--yes]
                                          burn (downloads first when --iso is not given)
                                          DISK is the disk number from --list, e.g. 2
  tomos-installer-tui --update            update this tool
  tomos-installer-tui --uninstall         remove this tool
  tomos-installer-tui --version | --help

${CB}EXAMPLES$C0
  tomos-installer-tui --burn 2                       ${MUTED}# run in an Administrator terminal$C0
  tomos-installer-tui --burn 2 --iso C:\Users\me\Downloads\tomos-26.10-amd64.iso

${CB}ENVIRONMENT$C0
  TOMOS_TUI_DIR            where downloads are kept (default: $DL_DIR)
  TOMOS_TUI_ALLOW_DEVICE   extra disk number(s) to offer, e.g. a card reader not seen as USB
"@
}
function Cli-List([bool]$all) {
  '{0,-6} {1,10}  {2,-34} {3}' -f 'DISK', 'SIZE', 'NAME', 'NOTE'
  $any = $false
  foreach ($d in (Get-Drives)) {
    if (-not $all -and (-not $d.Removable -or $d.System -or $d.ReadOnly)) { continue }
    $note = ''
    if ($d.System) { $note = 'system disk (protected)' } elseif ($d.ReadOnly) { $note = 'write protected' } elseif (-not $d.Removable) { $note = "internal ($($d.Bus))" } elseif ($d.Mounts) { $note = "mounted: $($d.Mounts)" }
    '{0,-6} {1,10}  {2,-34} {3}' -f $d.Dev, (Human $d.Size), (Trunc $d.Name 34), $note
    $any = $true
  }
  if (-not $any) { 'No USB drives found - plug in a USB stick (8 GB or bigger).' }
}
function Cli-Burn([string]$spec, [string]$iso, [bool]$yes, [bool]$tui) {
  if (-not $spec) { Fail '--burn needs a disk number (see --list)' }
  $d = Find-Drive $spec
  if (-not $d) { Fail "no disk $spec (see --list --all)" }
  if ($d.System) { Fail "disk $($d.Dev) holds Windows - refusing" }
  if ($d.ReadOnly) { Fail "disk $($d.Dev) is write protected" }
  if (-not $d.Removable) { Fail "disk $($d.Dev) is an internal disk ($($d.Bus)), not a USB stick - refusing. If you really mean it: set TOMOS_TUI_ALLOW_DEVICE=$($d.Dev)" }
  if (-not $tui -and -not (Is-Admin)) { Fail 'writing to a disk needs Administrator - open PowerShell or Terminal with "Run as administrator"' }
  if ($iso) {
    if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { Fail "no such file: $iso" }
    $iso = (Resolve-Path -LiteralPath $iso).Path
    if (-not $TS.IsoSha) { if (Fetch-Manifest) { } }
    $keep = $TS.IsoSha; Use-Iso $iso; if ($keep -and -not $TS.IsoSha) { $TS.IsoSha = $keep }
  } else {
    [Console]::Error.WriteLine("${PINK}${CB}==>${C0} Checking the latest Tom OS release$G_ELL")
    if (-not (Fetch-Manifest)) { Fail $TS.ManifestError }
    if (-not (Do-Download $true)) { Fail $TS.Message }
  }
  if ($d.Size -lt $TS.IsoSize) { Fail "disk $($d.Dev) is too small ($(Human $d.Size)) for $(Human $TS.IsoSize)" }
  $TS.Drive = $d
  if ($tui) {
    Enter-Tui
    try { $ok = Burn-Tui } finally { Exit-Tui }
    if ($ok) { exit 0 } else { exit 1 }
  }
  if (-not $yes) {
    [Console]::Error.WriteLine("`n${YELLOW}${CB}WARNING:$C0 everything on ${CB}disk $($d.Dev)$C0 - $($d.Name) ($(Human $d.Size)) will be erased.")
    if (-not $d.Removable) { [Console]::Error.WriteLine("$RED${CB}This is NOT a removable drive.$C0") }
    [Console]::Error.Write("Type disk$($d.Dev) to continue: ")
    $ans = [Console]::ReadLine()
    if ($ans -ne "disk$($d.Dev)") { Fail 'cancelled, nothing was written' }
  }
  $res = Burn-Core $d $TS.IsoPath $true
  if ($res -ne 'ok') { Fail $res }
  [Console]::Error.WriteLine("$GREEN$CB$G_OK$C0 Tom OS is on disk $($d.Dev) - boot from it with F12 / F11 / F8 / Esc")
}
function Self-Update {
  Invoke-RestMethod 'https://raw.githubusercontent.com/Spruhantom/tomos-installer-tui/main/install.ps1' | Invoke-Expression
}
function Self-Uninstall {
  $dir = Join-Path $env:LOCALAPPDATA 'TomOS\installer-tui'
  $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Tom OS Installer TUI.lnk'
  Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
  $bin = Join-Path $dir 'bin'
  $p = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($p) { [Environment]::SetEnvironmentVariable('Path', (($p -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User') }
  Write-Host "Removed the shortcut and PATH entry. Delete $dir to finish (downloads in $DL_DIR are kept)."
  Start-Process -FilePath cmd.exe -ArgumentList '/c', "timeout /t 2 >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden
}

function Demo([string]$what) {
  $env:TOMOS_TUI_DEMO = '1'
  Enter-Tui
  $TS.Version = '26.10'; $TS.IsoName = 'tomos-26.10-amd64.iso'; $TS.TotalSize = 2761211904; $TS.RemoteSha = 'x'
  $iso = 'C:\Users\Tom\Downloads\TomOS\tomos-26.10-amd64.iso'
  $stick = [pscustomobject]@{ Dev = '2'; Path = '\\.\PhysicalDrive2'; Size = 32017047552; Name = 'SanDisk Ultra Fit USB Device'; Removable = $true; System = $false; ReadOnly = $false; Mounts = 'E:'; Sector = 512; Bus = 'USB' }
  switch ($what) {
    'menu' { $TS.IsoPath = $iso; $TS.IsoSize = 2761211904; $TS.IsoVerified = $true; $TS.Message = "Downloaded and verified Tom OS 26.10 -> $iso"; $TS.Kind = 'ok'; Menu-Screen }
    'menu-ready' { $TS.IsoPath = $iso; $TS.IsoSize = 2761211904; $TS.IsoVerified = $true; $TS.Drive = $stick; $TS.Message = "Drive: $($stick.Name) (Disk 2)"; $TS.Kind = 'ok'; Menu-Screen }
    'drives' { $TS.IsoPath = $iso; $TS.IsoSize = 2761211904; Drive-Screen }
    'confirm' { $TS.IsoPath = $iso; $TS.IsoSize = 2761211904; $TS.Drive = $stick; Confirm-Screen | Out-Null }
    'burn' { $st = @((Step 'done' 'Clean Disk 2'), (Step 'now' 'Write tomos-26.10-amd64.iso'), (Step 'todo' 'Read back and verify'), (Step 'todo' 'Finish'))
      Progress-Screen 'BURNING TOM OS' "$($stick.Name) $G_MID Disk 2" 1610612736 2761211904 ((Now) - 82) $st; Read-Key | Out-Null }
    'done' { $TS.Drive = $stick; Done-Screen }
    'help' { Help-Screen }
  }
  Exit-Tui
}

# ------------------------------------------------------------------ main
function Main([string[]]$argv) {
  $action = 'tui'; $burn = ''; $iso = ''; $yes = $false; $all = $false; $demo = ''
  for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = $argv[$i].ToLower() -replace '^-{1,2}', '--'
    switch ($a) {
      { $_ -in '--h', '--help', '--?' } { Usage; return }
      { $_ -in '--v', '--version' } { "tomos-installer-tui $TUI_VERSION (Windows)"; return }
      { $_ -in '--list', '--l' } { $action = 'list' }
      '--all' { $all = $true; $TS.ShowAll = $true }
      '--info' { $action = 'info' }
      '--download' { $action = 'download' }
      '--burn' { $action = 'burn'; $i++; $burn = $argv[$i] }
      '--burn-tui' { $action = 'burn-tui'; $i++; $burn = $argv[$i] }
      '--iso' { $i++; $iso = $argv[$i] }
      '--sha' { $i++; $TS.IsoSha = $argv[$i] }
      { $_ -in '--yes', '--y' } { $yes = $true }
      '--no-verify' { $TS.Verify = $false }
      '--update' { Self-Update; return }
      '--uninstall' { Self-Uninstall; return }
      '--demo-screen' { $action = 'demo'; $i++; $demo = $argv[$i] }
      default { Usage; Fail "unknown option: $($argv[$i])" }
    }
  }
  switch ($action) {
    'list' { Cli-List $all }
    'info' {
      if (-not (Fetch-Manifest)) { Fail $TS.ManifestError }
      "Tom OS $($TS.Version)  (github.com/$OWNER/$REPO)"
      "ISO      $($TS.IsoName)  $(Human $TS.TotalSize)"
      "SHA-256  $($TS.RemoteSha)"
      foreach ($p in $TS.Parts) { "  $($p.Name)  $(Human $p.Size)" }
    }
    'download' {
      [Console]::Error.WriteLine("${PINK}${CB}==>${C0} Checking the latest Tom OS release$G_ELL")
      if (-not (Fetch-Manifest)) { Fail $TS.ManifestError }
      [Console]::Error.WriteLine("    Tom OS $($TS.Version) - $($TS.IsoName) ($(Human $TS.TotalSize))")
      if (-not (Do-Download $true)) { Fail $TS.Message }
      [Console]::Error.WriteLine("$GREEN$CB$G_OK$C0 Saved to $($TS.IsoPath)")
    }
    'burn' { Cli-Burn $burn $iso $yes $false }
    'burn-tui' { Cli-Burn $burn $iso $true $true }
    'demo' { Demo $demo }
    'tui' {
      if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { Fail 'run this in a terminal (or see --help for command-line use)' }
      Enter-Tui
      try { Menu-Screen } finally { Exit-Tui }
      Write-Host "${PINK}${CB}Tom OS Installer TUI$C0 - bye."
    }
  }
}

Main $args
