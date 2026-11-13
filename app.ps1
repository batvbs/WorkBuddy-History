<#
  WorkBuddy Keeper 1.9.9
  Session backup / restore + account switch for the WorkBuddy desktop client.
  Supports both editions (China and international) side by side.

  Design notes
  - Zero dependency: runs on the Windows PowerShell 5.1 that ships with Windows 10/11.
  - No SQLite, no external modules. Conversations, accounts and backups are handled
    with plain file copying only; the sole outbound requests are the model
    probes, which go to the endpoint the user configures.
  - Session data lives in the per-edition home (workbuddy.db + projects/**):
        China edition          %USERPROFILE%\.workbuddy
        international edition  %USERPROFILE%\.workbuddy-ai
    The two roots are never mixed: scanning, backup and restore are all scoped to
    one edition.
  - Login state lives in %LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\<product>.info
        China edition          workbuddy-desktop.info
        international edition  workbuddy-desktop-ai.info
  - The .info file is copied whole (never decrypted, never forged).
  - The UI is ui.html, served on 127.0.0.1 and shown in an Edge/Chrome --app window.

  This file is intentionally ASCII-only so that Windows PowerShell 5.1 parses it
  identically under any system code page.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$Root = '',
    [string]$WbHome = '',
    [string]$WbHomeAi = '',
    [string]$AuthDir = '',
    [switch]$NoBrowser,
    [switch]$NoProcessControl,
    [switch]$KeepAlive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$AppVersion = '1.9.9'

# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $Root) { $Root = $ScriptDir }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $WbHome) { $WbHome = Join-Path $env:USERPROFILE '.workbuddy' }
$WbHome = [IO.Path]::GetFullPath($WbHome)
if (-not $WbHomeAi) { $WbHomeAi = Join-Path $env:USERPROFILE '.workbuddy-ai' }
$WbHomeAi = [IO.Path]::GetFullPath($WbHomeAi)
if (-not $AuthDir) { $AuthDir = Join-Path $env:LOCALAPPDATA 'CodeBuddyExtension\Data\Public\auth' }
$AuthDir = [IO.Path]::GetFullPath($AuthDir)

$ProfilesDir = Join-Path $Root 'profiles'
$BackupsDir = Join-Path $Root 'backups'
$DataDir = Join-Path $Root 'data'
$UiPath = Join-Path $ScriptDir 'ui.html'
$LogPath = Join-Path $DataDir 'activity.log'
$StatePath = Join-Path $DataDir 'state.json'
$NicknamesPath = Join-Path $DataDir 'nicknames.json'
$DbSnapshotsDir = Join-Path $DataDir 'db-snapshots'

foreach ($d in @($ProfilesDir, $BackupsDir, $DataDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# product id == file name stem of the .info file.
# Home: the per-edition data root. The China edition keeps everything in
# %USERPROFILE%\.workbuddy, the international edition in %USERPROFILE%\.workbuddy-ai.
# Sessions, sidebar snapshots and the sqlite db are all inside that root, so the
# two editions never share data and must never be mixed.
$Products = @(
    @{ Id = 'workbuddy-desktop';    Proc = 'WorkBuddy';   Home = $WbHome;   Domain = 'workbuddy.cn' },
    @{ Id = 'workbuddy-desktop-ai'; Proc = 'WorkBuddyAI'; Home = $WbHomeAi; Domain = 'workbuddy.ai' }
)

$script:Token = ''
$script:Busy = $false
$script:LastPing = Get-Date
$script:Pinged = $false
$script:StartAt = Get-Date
$script:LastTick = Get-Date
$script:SessionCache = @{}
$script:SessionCacheAt = @{}
$script:InstancePath = Join-Path $DataDir 'instance.json'
$script:WindowWatch = $false      # true once we opened an app window ourselves
$script:ListenPort = 0            # set once the listener binds; used to check Host
$script:SawWindow = $false
$script:WinGone = 0
$script:LastWinCheck = Get-Date
# The window title is ui.html's <title>, spelled in code points so this file stays
# pure ASCII: PowerShell 5.1 decodes a BOM-less .ps1 as ANSI, which would turn any
# literal Chinese here into mojibake and the probe would never match.
# The space matters: an Explorer window sitting in the program folder is titled
# "WorkBuddy<no space>..." and must not be mistaken for the app window.
$script:WindowTitle = 'WorkBuddy ' + [string]([char]0x5BF9 + [char]0x8BDD + [char]0x7BA1 + [char]0x5BB6)

# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
function Write-Log([string]$msg) {
    try {
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
        [IO.File]::AppendAllText($LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-NowMs {
    return [long][System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function ConvertTo-Ms([datetime]$dt) {
    return [long]([System.DateTimeOffset]::new($dt.ToUniversalTime()).ToUnixTimeMilliseconds())
}

function ConvertFrom-Ms([long]$ms) {
    if ($ms -le 0) { return $null }
    return [System.DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if (-not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$path, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 10
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FolderSize([string]$path) {
    $sum = 0
    try {
        $r = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        if ($r -and $r.Sum) { $sum = $r.Sum }
    } catch { }
    return [long]$sum
}

function Copy-Tree([string]$src, [string]$dst, [string]$flattenSelf, [switch]$Strict) {
    # Copy the CONTENTS of $src into $dst, ONE FILE AT A TIME, rebuilding the
    # relative path by hand.
    #
    # NOT `Copy-Item -LiteralPath $src -Destination $dst -Recurse`, and not even
    # per-child `Copy-Item -Destination $dst -Recurse`: whenever the destination
    # already holds an entry with the same name as the source child, Copy-Item
    # MERGES instead of replacing and the subtree lands one level too deep -
    # dst\AAA\AAA\inner\f.txt. Session attachment folders are named after the
    # session id and are copied into a folder of the same name, so that merged
    # copy used to nest a folder inside itself - every restore added one more
    # level, and every backup carried it, which is why backups kept growing.
    #
    # $flattenSelf normalises such a self-nested folder: leading path segments
    # equal to it are stripped, so <id>/<id>/tool-results/a.txt lands at
    # <id>/tool-results/a.txt. Only restore passes it - restore is the operation
    # allowed to rewrite the home layout and it is where the nesting came from.
    # Backup and fork never flatten, because they must not lose a file.
    #
    # Two different rules, because the two kinds of source file mean different
    # things:
    #   canonical (not flattened) - the real attachment at its real path. Restore
    #     REPLACES what is there; that is what restoring a conversation means.
    #     A directory sitting on the name is never deleted - the file takes a
    #     free name next to it instead.
    #   flattened - a copy left behind by the old nesting bug. It is kept only
    #     when its content is not already present: an occupied name is compared
    #     by SHA256 (equal length is not identity: AB vs CD), and anything that
    #     is not an exact duplicate is stored as name-innerN.ext.
    # Neither rule may drop a file silently: running out of names throws rather
    # than pretending the copy succeeded, and -Strict turns every failure into an
    # exception, because Fork-Session commits the database once this returns.

    function New-FreePath([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { return $path }
        $d = Split-Path -Parent $path
        $n0 = [IO.Path]::GetFileNameWithoutExtension($path)
        $e0 = [IO.Path]::GetExtension($path)
        for ($i = 1; $i -lt 100000; $i++) {
            $c = Join-Path $d ($n0 + '-inner' + $i + $e0)
            if (-not (Test-Path -LiteralPath $c)) { return $c }
        }
        throw ('copy_target_exhausted: ' + $path)
    }

    function Test-ParentDir([string]$path, [bool]$hard) {
        $parent = Split-Path -Parent $path
        if (-not $parent) { return $true }
        if (Test-Path -LiteralPath $parent -PathType Container) { return $true }
        if (Test-Path -LiteralPath $parent -PathType Leaf) { return $false }
        try {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
            return $true
        } catch {
            if ($hard) { throw }
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $src)) { return }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    $srcRoot = [IO.Path]::GetFullPath($src).TrimEnd('\')
    $dstRoot = [IO.Path]::GetFullPath($dst).TrimEnd('\')
    $errAction = 'SilentlyContinue'
    if ($Strict) { $errAction = 'Stop' }
    $hard = [bool]$Strict

    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force -ErrorAction $errAction)) {
        $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
        if (-not $rel) { continue }
        $flat = $rel
        if ($flattenSelf) {
            $prefix = $flattenSelf + '\'
            while ($flat.Length -gt $prefix.Length -and
                   $flat.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $flat = $flat.Substring($prefix.Length)
            }
        }
        $plan.Add([pscustomobject]@{ File = $f; Flat = $flat; Stripped = ($flat -ne $rel) })
    }

    # canonical files claim their names first, whatever order the tree was walked
    $ordered = @($plan | Where-Object { -not $_.Stripped }) + @($plan | Where-Object { $_.Stripped })

    foreach ($it in $ordered) {
        $f = $it.File
        $rel = $it.Flat
        $target = $null

        # wanted path first; if a file sits where the path needs a directory, fall
        # back once to a flat name in the root. Strict mode never falls back: a
        # silent layout change is exactly what a fork must not report as success.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $cand = Join-Path $dstRoot $rel
            if (Test-ParentDir $cand $hard) { $target = $cand; break }
            if ($hard) { throw ('copy_parent_blocked: ' + $cand) }
            $rel = ($it.Flat -replace '\\', '-')
        }
        if (-not $target) { continue }

        if (-not $it.Stripped) {
            if (Test-Path -LiteralPath $target -PathType Container) { $target = New-FreePath $target }
            try { Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop }
            catch { if ($hard) { throw } else { Write-Log ('copy failed: ' + $f.FullName + ' -> ' + $target) } }
            continue
        }

        $skip = $false
        $chosen = $null
        $csDir = Split-Path -Parent $target
        $csName = [IO.Path]::GetFileNameWithoutExtension($target)
        $csExt = [IO.Path]::GetExtension($target)
        for ($i = 0; $i -lt 100000; $i++) {
            $cand = $target
            if ($i -gt 0) { $cand = Join-Path $csDir ($csName + '-inner' + $i + $csExt) }
            if (-not (Test-Path -LiteralPath $cand)) { $chosen = $cand; break }
            $existing = Get-Item -LiteralPath $cand -Force -ErrorAction SilentlyContinue
            if ($existing -and -not $existing.PSIsContainer -and $existing.Length -eq $f.Length) {
                $hSrc = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
                $hDst = Get-FileHash -LiteralPath $cand -Algorithm SHA256 -ErrorAction SilentlyContinue
                if ($hSrc -and $hDst -and $hSrc.Hash -eq $hDst.Hash) { $skip = $true; break }
            }
        }
        if ($skip) { continue }
        if (-not $chosen) { throw ('copy_target_exhausted: ' + $target) }
        try { Copy-Item -LiteralPath $f.FullName -Destination $chosen -Force -ErrorAction Stop }
        catch { if ($hard) { throw } else { Write-Log ('copy failed: ' + $f.FullName + ' -> ' + $chosen) } }
    }
}

function Mask-Uin([string]$uin) {
    if (-not $uin) { return '' }
    if ($uin.Length -le 6) { return $uin }
    return $uin.Substring(0, 3) + '****' + $uin.Substring($uin.Length - 4)
}

function Get-DisplayName([string]$uid) {
    if (-not $uid) { return 'unknown' }
    # a uid is a uuid, but keep this safe for hand-made or truncated rows
    if ($uid.Length -le 8) { return $uid }
    return $uid.Substring(0, 8)
}

# --------------------------------------------------------------------------
# sqlite
#
# Every conversation lives in one SQLite database (<edition home>\workbuddy.db,
# table "sessions"). Reading titles/owners out of that file by hand is guesswork,
# and writing to it by hand is worse: the client keeps the database in WAL mode,
# so a raw byte patch is silently rolled back the next time the client writes.
#
# Windows ships a real SQLite engine as %WINDIR%\System32\winsqlite3.dll, so we
# bind it directly. No download, no external module, and the update goes through
# the same code path the client itself uses, which keeps the WAL consistent.
# --------------------------------------------------------------------------
$script:SqliteReady = $false

function Initialize-Sqlite {
    if ($script:SqliteReady) { return }
    $code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WbSqlite
{
    const string Dll = "winsqlite3.dll";
    static readonly IntPtr Transient = new IntPtr(-1);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_libversion();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nBytes, out IntPtr stmt, IntPtr tail);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr stmt, int i);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_type(IntPtr stmt, int i);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] val, int n, IntPtr destructor);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_changes(IntPtr db);

    public static string Version()
    {
        return Marshal.PtrToStringAnsi(sqlite3_libversion());
    }

    static byte[] Utf8Z(string s)
    {
        byte[] raw = Encoding.UTF8.GetBytes(s);
        byte[] buf = new byte[raw.Length + 1];
        Array.Copy(raw, buf, raw.Length);
        return buf;
    }

    public static IntPtr Open(string path)
    {
        IntPtr db;
        int rc = sqlite3_open_v2(Utf8Z(path), out db, 0x2 | 0x4 | 0x10000, IntPtr.Zero);
        if (rc != 0)
        {
            string msg = db != IntPtr.Zero ? Err(db) : ("rc=" + rc);
            if (db != IntPtr.Zero) sqlite3_close_v2(db);
            throw new Exception("sqlite_open_failed: " + msg);
        }
        return db;
    }

    public static string Err(IntPtr db)
    {
        IntPtr p = sqlite3_errmsg(db);
        return p == IntPtr.Zero ? "" : Marshal.PtrToStringAnsi(p);
    }

    public static void Close(IntPtr db)
    {
        sqlite3_close_v2(db);
    }

    static string ColText(IntPtr stmt, int i)
    {
        if (sqlite3_column_type(stmt, i) == 5) return null;
        IntPtr p = sqlite3_column_text(stmt, i);
        if (p == IntPtr.Zero) return "";
        int n = sqlite3_column_bytes(stmt, i);
        if (n <= 0) return "";
        byte[] buf = new byte[n];
        Marshal.Copy(p, buf, 0, n);
        return Encoding.UTF8.GetString(buf);
    }

    static void Bind(IntPtr stmt, string[] args)
    {
        if (args == null) return;
        for (int i = 0; i < args.Length; i++)
        {
            byte[] raw = args[i] == null ? null : Encoding.UTF8.GetBytes(args[i]);
            sqlite3_bind_text(stmt, i + 1, raw, raw == null ? 0 : raw.Length, Transient);
        }
    }

    public static List<Dictionary<string, string>> Query(IntPtr db, string sql, string[] args)
    {
        IntPtr stmt;
        if (sqlite3_prepare_v2(db, Utf8Z(sql), -1, out stmt, IntPtr.Zero) != 0)
            throw new Exception("sqlite_prepare_failed: " + Err(db));
        try
        {
            Bind(stmt, args);
            List<Dictionary<string, string>> rows = new List<Dictionary<string, string>>();
            while (true)
            {
                int rc = sqlite3_step(stmt);
                if (rc == 100)
                {
                    int c = sqlite3_column_count(stmt);
                    Dictionary<string, string> row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 0; i < c; i++)
                    {
                        IntPtr np = sqlite3_column_name(stmt, i);
                        string name = np == IntPtr.Zero ? ("c" + i) : Marshal.PtrToStringAnsi(np);
                        row[name] = ColText(stmt, i);
                    }
                    rows.Add(row);
                }
                else if (rc == 101) break;
                else throw new Exception("sqlite_step_failed rc=" + rc + ": " + Err(db));
            }
            return rows;
        }
        finally { sqlite3_finalize(stmt); }
    }

    public static int Exec(IntPtr db, string sql, string[] args)
    {
        IntPtr stmt;
        if (sqlite3_prepare_v2(db, Utf8Z(sql), -1, out stmt, IntPtr.Zero) != 0)
            throw new Exception("sqlite_prepare_failed: " + Err(db));
        try
        {
            Bind(stmt, args);
            while (true)
            {
                int rc = sqlite3_step(stmt);
                if (rc == 101) break;
                if (rc == 100) continue;
                throw new Exception("sqlite_step_failed rc=" + rc + ": " + Err(db));
            }
            return sqlite3_changes(db);
        }
        finally { sqlite3_finalize(stmt); }
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp
    $script:SqliteReady = $true
    Write-Log ('sqlite bound: winsqlite3 ' + [WbSqlite]::Version())
}

function Open-WbDatabase([string]$product) {
    $dbPath = Join-Path (Get-EditionHome $product) 'workbuddy.db'
    return (Open-WbDatabasePath $dbPath)
}

function Open-WbDatabasePath([string]$dbPath) {
    Initialize-Sqlite
    if (-not (Test-Path -LiteralPath $dbPath)) { throw 'no_database' }
    $db = [WbSqlite]::Open($dbPath)
    [void][WbSqlite]::Exec($db, 'PRAGMA busy_timeout=8000', $null)
    return $db
}

# --------------------------------------------------------------------------
# account / auth
# --------------------------------------------------------------------------
function Get-ProductProc([string]$product) {
    foreach ($p in $Products) { if ($p.Id -eq $product) { return $p.Proc } }
    return 'WorkBuddy'
}

function Test-Edition([string]$product) {
    if (-not $product) { return $false }
    foreach ($p in $Products) { if ($p.Id -eq $product) { return $true } }
    return $false
}

function Get-EditionHome([string]$product) {
    foreach ($p in $Products) { if ($p.Id -eq $product) { return $p.Home } }
    return $WbHome
}

function Get-InfoPath([string]$product) {
    return (Join-Path $AuthDir ($product + '.info'))
}

function Read-AuthInfo([string]$product) {
    $path = Get-InfoPath $product
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    try { $j = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $j -or -not $j.account) { return $null }

    $acc = $j.account
    $au = $j.auth
    $item = Get-Item -LiteralPath $path
    $expiresAt = 0; $refreshExpiresAt = 0; $lastRefreshTime = 0
    if ($au) {
        if ($au.expiresAt) { $expiresAt = [long]$au.expiresAt }
        if ($au.refreshExpiresAt) { $refreshExpiresAt = [long]$au.refreshExpiresAt }
        if ($au.lastRefreshTime) { $lastRefreshTime = [long]$au.lastRefreshTime }
    }
    $out = [pscustomobject]@{
        product          = $product
        proc             = (Get-ProductProc $product)
        uid              = [string]$acc.uid
        uin              = [string]$acc.uin
        domain           = ''
        expiresAt        = $expiresAt
        refreshExpiresAt = $refreshExpiresAt
        lastRefreshTime  = $lastRefreshTime
        size             = [long]$item.Length
        fileTime         = (ConvertTo-Ms $item.LastWriteTimeUtc)
    }
    if ($au -and $au.domain) { $out.domain = [string]$au.domain }
    return $out
}

function Get-EditionRunning([string]$product) {
    return ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0)
}

function Get-ActiveEdition {
    # Which edition the user is "in" right now.
    # Rank: a client with a visible main window beats a headless one, and among
    # equals the login state written last wins (that is the one that just renewed).
    $best = ''
    $bestScore = [long]-1
    foreach ($p in $Products) {
        if (-not (Get-EditionRunning $p.Id)) { continue }
        $hasWindow = $false
        foreach ($pr in (Get-ClientProcesses $p.Proc)) {
            try { if ($pr.MainWindowHandle -ne 0) { $hasWindow = $true; break } } catch { }
        }
        $a = Read-AuthInfo $p.Id
        $t = [long]0
        if ($a) { $t = [long]$a.fileTime }
        # window flag dominates; timestamp only breaks ties
        $score = $t
        if ($hasWindow) { $score = $t + 315360000000 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $p.Id }
    }
    if ($best) { return $best }
    $bestScore = [long]-1
    foreach ($p in $Products) {
        $a = Read-AuthInfo $p.Id
        if (-not $a) { continue }
        if ($a.fileTime -gt $bestScore) { $bestScore = $a.fileTime; $best = $p.Id }
    }
    if ($best) { return $best }
    return $Products[0].Id
}

function Get-CurrentAccount([string]$product) {
    # With a product argument: the login state of exactly that edition.
    # Without: the login state of the active edition.
    if ($product) {
        $a = Read-AuthInfo $product
        if ($a -and $a.uid) { return $a }
        return $null
    }
    $a2 = Read-AuthInfo (Get-ActiveEdition)
    if ($a2 -and $a2.uid) { return $a2 }
    return $null
}

function Get-AllAuthInfos {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Products) {
        $a = Read-AuthInfo $p.Id
        if ($a -and $a.uid) { $list.Add($a) }
    }
    return ,$list.ToArray()
}

# --------------------------------------------------------------------------
# profiles (saved login states)
# --------------------------------------------------------------------------
function Get-ProfileMetaPath([string]$product, [string]$uid) {
    return (Join-Path (Join-Path $ProfilesDir $product) ($uid + '.json'))
}

function Get-ProfileInfoPath([string]$product, [string]$uid) {
    return (Join-Path (Join-Path $ProfilesDir $product) ($uid + '.info'))
}

function Save-Profile([string]$product) {
    $info = Read-AuthInfo $product
    if (-not $info) { throw 'no_login_state' }
    $dir = Join-Path $ProfilesDir $product
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $src = Get-InfoPath $product
    $dst = Get-ProfileInfoPath $product $info.uid
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $meta = [pscustomobject]@{
        product          = $product
        uid              = $info.uid
        uin              = $info.uin
        domain           = $info.domain
        savedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        refreshExpiresAt = $info.refreshExpiresAt
        expiresAt        = $info.expiresAt
        lastRefreshTime  = $info.lastRefreshTime
        size             = $info.size
    }
    Write-JsonFile (Get-ProfileMetaPath $product $info.uid) $meta
    Write-Log ("profile saved: {0} {1}" -f $product, $info.uid)
    return $meta
}

function Get-Profiles {
    # "current" is per edition: both editions can be logged in at the same time,
    # so a profile is current when it matches the live login state of its own edition.
    $curMap = @{}
    foreach ($p in $Products) {
        $a = Read-AuthInfo $p.Id
        if ($a -and $a.uid) { $curMap[$p.Id] = $a.uid }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Products) {
        $dir = Join-Path $ProfilesDir $p.Id
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $meta = Read-JsonFile $f.FullName
            if (-not $meta -or -not $meta.uid) { continue }
            $uid = [string]$meta.uid
            $infoPath = Get-ProfileInfoPath $p.Id $uid
            if (-not (Test-Path -LiteralPath $infoPath)) { continue }
            $isCurrent = ($curMap.ContainsKey($p.Id) -and $curMap[$p.Id] -eq $uid)
            $refreshExpires = 0
            if ($meta.refreshExpiresAt) { $refreshExpires = [long]$meta.refreshExpiresAt }
            $days = 0
            if ($refreshExpires -gt 0) { $days = [int][Math]::Floor(($refreshExpires - (Get-NowMs)) / 86400000.0) }
            $list.Add([pscustomobject]@{
                product          = $p.Id
                uid              = $uid
                shortUid         = (Get-DisplayName $uid)
                uin              = [string]$meta.uin
                uinMask          = (Mask-Uin ([string]$meta.uin))
                nickname         = (Get-Nickname $p.Id $uid)
                domain           = [string]$meta.domain
                savedAt          = [string]$meta.savedAt
                refreshExpiresAt = $refreshExpires
                refreshExpires   = (ConvertFrom-Ms $refreshExpires)
                lastRefresh      = (ConvertFrom-Ms ([long]$meta.lastRefreshTime))
                daysLeft         = $days
                expired          = ($days -lt 0)
                isCurrent        = $isCurrent
                size             = (Get-Item -LiteralPath $infoPath).Length
            })
        }
    }
    return ,$list.ToArray()
}

function Sync-Profiles {
    # keep saved snapshots fresh: the client rotates refresh tokens every renewal.
    # This must run for EVERY edition: when both clients are open, the edition that
    # is not "active" still renews its token, and its snapshot would silently rot.
    foreach ($p in $Products) {
        $current = Read-AuthInfo $p.Id
        if (-not $current -or -not $current.uid) { continue }
        $metaPath = Get-ProfileMetaPath $current.product $current.uid
        if (-not (Test-Path -LiteralPath $metaPath)) { continue }
        $meta = Read-JsonFile $metaPath
        if (-not $meta) { continue }
        $stored = 0
        if ($meta.lastRefreshTime) { $stored = [long]$meta.lastRefreshTime }
        $storedExp = 0
        if ($meta.refreshExpiresAt) { $storedExp = [long]$meta.refreshExpiresAt }
        if ($current.lastRefreshTime -gt $stored -or $current.refreshExpiresAt -gt $storedExp) {
            try {
                [void](Save-Profile $current.product)
                Write-Log ('profile auto-synced after token renewal: ' + $current.product)
            } catch {
                Write-Log ('profile auto-sync failed: ' + $current.product + ' ' + $_.Exception.Message)
            }
        }
    }
}

# --------------------------------------------------------------------------
# nicknames
# Local only: the real nickname inside the .info file is encrypted and this tool
# never decrypts it. A nickname here is just a label the user types, stored in
# data/nicknames.json keyed by "product:uid". It survives profile re-saves.
# --------------------------------------------------------------------------
function Get-NicknameMap {
    $map = @{}
    $j = Read-JsonFile $NicknamesPath
    if ($j) {
        foreach ($pp in $j.PSObject.Properties) { $map[$pp.Name] = [string]$pp.Value }
    }
    return $map
}

function Get-Nickname([string]$product, [string]$uid) {
    if (-not $product -or -not $uid) { return '' }
    $map = Get-NicknameMap
    $key = $product + ':' + $uid
    if ($map.ContainsKey($key)) { return [string]$map[$key] }
    return ''
}

function Set-Nickname([string]$product, [string]$uid, [string]$nickname) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    if (-not $uid) { throw 'params_required' }
    $map = Get-NicknameMap
    $key = $product + ':' + $uid
    $v = ''
    if ($null -ne $nickname) { $v = ([string]$nickname).Trim() }
    if ($v.Length -gt 24) { $v = $v.Substring(0, 24) }
    if ($v) { $map[$key] = $v }
    elseif ($map.ContainsKey($key)) { $map.Remove($key) }
    $obj = [pscustomobject]@{}
    foreach ($k in @($map.Keys)) {
        $obj | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$map[$k])
    }
    Write-JsonFile $NicknamesPath $obj
    Write-Log ("nickname set: {0} {1} -> {2}" -f $product, $uid, $v)
    return $v
}

function Find-NicknameAny([hashtable]$map, [string]$uid) {
    # Backups written before the edition field existed, and backups whose
    # manifest no longer names a product, still have to be labelled with the
    # nickname the user typed. The uids are globally unique, so the only key
    # ending in ':uid' is the right one; a product-qualified lookup is tried
    # first by the caller and this is the fallback.
    if (-not $uid) { return '' }
    foreach ($k in @($map.Keys)) {
        if ($k.EndsWith(':' + $uid)) { return [string]$map[$k] }
    }
    return ''
}

function Get-ModelVendorHint([string]$id, [string]$name) {
    # Guesses the client's "vendor" value from a model id / display name, using
    # the same keyword rules the UI uses for its automatic icon match. The
    # client picks the icon by looking this vendor up in its built-in provider
    # table, so writing it is what makes an imported model show the right logo.
    #
    # Keep in sync with mdlAutoIconFor()/ICON_VENDOR in ui.html: the icon the
    # batch list draws and the vendor that ends up in the file must agree, or a
    # model would be shown with one logo and saved under another.
    $hay = (([string]$id) + ' ' + ([string]$name)).ToLowerInvariant()
    if (-not $hay.Trim()) { return '' }
    # "hunyuan" spelled in code points so this file stays pure ASCII. The plain
    # ascii word alone is not enough: models are often named in Chinese only
    # (for example the Chinese spelling of "hunyuan" plus "-large"), and the
    # UI's own rule table already matched that spelling -
    # leaving it out here meant a Chinese-named Hunyuan row got vendor="Custom"
    # from the server and the UI then trusted that over its own rule, so the
    # model lost its logo. Keep this list in sync with mdlAutoIconFor().
    $hunyuanZh = [string]([char]0x6DF7 + [char]0x5143)
    $rules = @(
        @('kimi', 'Kimi'), @('moonshot', 'Kimi'),
        @('glm', 'GLM API'), @('zhipu', 'GLM API'), @('chatglm', 'GLM API'),
        @('deepseek', 'DeepSeek'),
        @('minimax', 'MiniMax'), @('abab', 'MiniMax'),
        @('hunyuan', 'Hunyuan'), @($hunyuanZh, 'Hunyuan'),
        @('gpt', 'OpenAI'), @('openai', 'OpenAI'),
        @('gemini', 'Google Gemini'), @('google', 'Google Gemini'),
        @('claude', 'Claude'), @('anthropic', 'Claude'),
        @('mistral', 'Mistral AI'),
        @('groq', 'Groq'),
        @('together', 'Together AI'),
        @('fireworks', 'Fireworks AI'),
        @('perplexity', 'Perplexity')
    )
    foreach ($r in $rules) {
        if ($hay.Contains([string]$r[0])) { return [string]$r[1] }
    }
    # OpenAI's reasoning ids are "o1", "o1-mini", "o3", "o3-mini" ... Matching
    # only the "o1-"/"o3-" spellings missed the bare ones, which then fell
    # through to Custom. Anchored so a random id ending in "o1" is not caught.
    if ($hay -match '(^|[\s\-_/])o[13](\b|[\s\-_/])') { return 'OpenAI' }
    return 'Custom'
}

function New-ListingItem($it, [string]$mid) {
    # One entry of a /models response, normalised. Only fields the client
    # actually understands are kept; the rest of the payload (created,
    # owned_by, supported_endpoint_types, ...) is noise for our purpose.
    #
    # The capability fields are read on a best-effort basis because gateways
    # differ wildly: DeepSeek reports context_window / max_output_tokens /
    # effort, others report none of them. Missing stays missing (0 / empty) so
    # the batch importer can tell "the listing did not say" from "it said no",
    # which is exactly what decides whether model.csv has to fill the gap.
    $o = [pscustomobject]@{
        id               = $mid
        name             = [string](Get-ModelProp $it 'name')
        vendor           = (Get-ModelVendorHint $mid ([string](Get-ModelProp $it 'name')))
        # 0 / '' mean "the listing did not tell us".
        maxInputTokens   = 0
        maxOutputTokens  = 0
        supportsImages   = $false
        supportsImagesSet = $false
        supportsReasoning = $false
        supportsReasoningSet = $false
        supportedEfforts = @()
        defaultEffort    = ''
    }
    if (-not $o.name) {
        $dn = Get-ModelProp $it 'display_name'
        if ($null -ne $dn) { $o.name = [string]$dn }
    }

    $v = Get-ModelProp $it 'context_window'
    if ($null -eq $v) { $v = Get-ModelProp $it 'context_length' }
    if ($null -eq $v) { $v = Get-ModelProp $it 'max_input_tokens' }
    if ($null -ne $v) { try { $o.maxInputTokens = [long]$v } catch { } }

    $v = Get-ModelProp $it 'max_output_tokens'
    if ($null -ne $v) { try { $o.maxOutputTokens = [long]$v } catch { } }

    # input_modalities: ["text","image"] -> supportsImages
    $mods = Get-ModelProp $it 'input_modalities'
    if ($null -ne $mods) {
        foreach ($mm in (To-ItemArray $mods)) {
            if (([string]$mm).ToLowerInvariant() -eq 'image') { $o.supportsImages = $true }
        }
        $o.supportsImagesSet = $true
    }

    # effort comes as {"supported_levels":[...], "default_level":"..."}; some
    # gateways instead put a plain array under "supported_efforts".
    $eff = Get-ModelProp $it 'effort'
    if ($null -ne $eff) {
        $lv = Get-ModelProp $eff 'supported_levels'
        if ($null -eq $lv) { $lv = Get-ModelProp $eff 'supportedEfforts' }
        if ($null -ne $lv) {
            $acc = New-Object System.Collections.Generic.List[string]
            foreach ($e in (To-ItemArray $lv)) {
                $s = ([string]$e).Trim()
                if ($s) { $acc.Add($s) }
            }
            if ($acc.Count -gt 0) { $o.supportedEfforts = $acc.ToArray(); $o.supportsReasoningSet = $true; $o.supportsReasoning = $true }
        }
        $dl = Get-ModelProp $eff 'default_level'
        if ($null -eq $dl) { $dl = Get-ModelProp $eff 'defaultEffort' }
        if ($null -ne $dl) { $o.defaultEffort = ([string]$dl).Trim() }
    }
    return $o
}

function Get-ModelsPath([string]$product) {
    # models.json lives next to the per-edition data root, not inside it: the
    # China edition is %USERPROFILE%\.workbuddy\models.json and the
    # international one %USERPROFILE%\.workbuddy-ai\models.json.
    # Not $home: that is a read-only built-in variable in PowerShell.
    $edRoot = Get-EditionHome $product
    if (-not $edRoot) { return '' }
    return (Join-Path $edRoot 'models.json')
}

function Get-ModelsRaw([string]$product) {
    # Returns the file text plus a reason when it is unusable. The client parses
    # this file with a plain JSON.parse and gives up silently on a syntax error,
    # so "is it valid" and "can I safely rewrite it" are the same question.
    $path = Get-ModelsPath $product
    $out = [pscustomobject]@{
        path  = $path
        exists = $false
        text  = ''
        valid = $false
        error = ''
        shape = 'none'
        wrapper = $null
        items = (New-Object System.Collections.Generic.List[object])
    }
    if (-not $path) { $out.error = 'unknown_edition'; return $out }
    if (-not (Test-Path -LiteralPath $path)) {
        # Say so explicitly. The viewer shows a completely different message for
        # "not created yet" than for "exists but unreadable", and an empty code
        # would make a fresh install look like a corrupted file.
        $out.error = 'models_missing'
        return $out
    }
    $out.exists = $true
    try {
        $out.text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    } catch {
        $out.error = 'read_failed'
        return $out
    }
    if (-not $out.text.Trim()) { $out.error = 'models_empty'; return $out }
    $parsed = ConvertFrom-ModelsText $out.text
    $out.shape = $parsed.shape
    $out.wrapper = $parsed.wrapper
    $out.items = $parsed.items
    if (-not $parsed.ok) {
        $out.error = 'models_malformed'
        return $out
    }
    $out.valid = $true
    return $out
}

function ConvertFrom-ModelsText([string]$text) {
    # models.json comes in two shapes and both have to be handled:
    #   [ {...}, {...} ]                 - a bare array (what this machine has)
    #   { "models": [ {...} ], ... }     - a wrapper object
    # The client accepts either. Returns the entries plus which shape was found,
    # so a write can be put back in the same shape it came from.
    #
    # items is a List, never a PowerShell array: an array returned from a
    # function is unrolled by the pipeline, so a one-entry list would arrive as
    # the bare entry and a wrapper property holding it looks like a scalar.
    $items = New-Object System.Collections.Generic.List[object]
    $out = [pscustomobject]@{ items = $items; shape = 'none'; ok = $false; wrapper = $null }
    if (-not $text -or -not $text.Trim()) { return $out }
    try {
        # Parsing without -InputObject keeps the top-level array intact; going
        # through the pipeline would emit its members one by one instead.
        $doc = $text | ConvertFrom-Json
    } catch {
        return $out
    }
    $out.ok = $true

    # Unroll explicitly, one level deep, whatever the top level turned out to be.
    $top = New-Object System.Collections.Generic.List[object]
    if ($null -ne $doc) {
        if ($doc -is [array]) { foreach ($e in $doc) { $top.Add($e) } }
        else { $top.Add($doc) }
    }

    if ($top.Count -ge 1) {
        $first = $top[0]
        $mm = $null
        if ($null -ne $first -and -not ($first -is [string]) -and -not ($first -is [ValueType])) {
            $mm = $first.PSObject.Properties['models']
        }
        if ($null -ne $mm) {
            # Wrapper object: entries live under "models". Keep the rest of the
            # wrapper (availableModels and anything else) so a write does not
            # silently drop keys that are nothing to do with this edit.
            $out.shape = 'object'
            $out.wrapper = $first
            $inner = $mm.Value
            if ($null -ne $inner) {
                if ($inner -is [array]) { foreach ($e in $inner) { $items.Add($e) } }
                else { $items.Add($inner) }
            }
            return $out
        }
    }

    # Bare array (or an empty one).
    $out.shape = 'array'
    foreach ($e in $top) { $items.Add($e) }
    return $out
}

function New-ModelsProps($entry) {
    # Keep the key order the user already has. Property order is preserved on
    # read, so re-serialising an untouched entry reproduces its own layout
    # instead of shuffling the file every time something else is edited.
    $props = New-Object 'System.Collections.Specialized.OrderedDictionary'
    foreach ($p in $entry.PSObject.Properties) { $props[$p.Name] = $p.Value }
    return $props
}

function Find-ModelEntryIndex($items, [string]$id, [int]$hint = -1) {
    # Index of the entry the user means when they act on $id, or -1.
    #
    # Duplicates are normal here: importing a model that already exists leaves a
    # visible entry plus a hidden twin, and both answer to the same id.
    #
    # $hint is the array position the UI saw, and when it is usable it WINS.
    # That is what makes acting on a hidden card work: the card is identified by
    # (id, position), and an id-only lookup would always resolve to the visible
    # twin - so clicking delete on the hidden card removed the visible one, and
    # clicking show on it did nothing at all (both verified). The hint is only
    # trusted when the entry at that position still carries the same id, so a
    # file changed in the client meanwhile falls back to the id rule instead of
    # hitting an unrelated row.
    #
    # Without a usable hint the visible twin still wins: that is the right
    # default for callers that only have an id (the editor opened from a list).
    # Falling back to a hidden twin keeps a purely hidden entry editable.
    #
    # The group-title marker is skipped outright. It is bookkeeping, not a model:
    # it never appears in the list, so an id lookup must never land on it - doing
    # so would silently destroy the group's title, or rewrite the marker instead
    # of the model the user actually clicked.
    if ($hint -ge 0 -and $null -ne $items -and $hint -lt $items.Count) {
        $he = $items[$hint]
        if ($null -ne $he -and -not (Test-GroupMarker $he) -and $id -and ((Get-ModelKey $he) -eq $id)) {
            return $hint
        }
    }
    if (-not $id) { return -1 }
    $hiddenIdx = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        $e = $items[$i]
        if ($null -eq $e) { continue }
        if (Test-GroupMarker $e) { continue }
        if ((Get-ModelKey $e) -ne $id) { continue }
        if (-not (Test-ModelArchived $e)) { return $i }
        if ($hiddenIdx -lt 0) { $hiddenIdx = $i }
    }
    return $hiddenIdx
}

function Get-ModelStoredApiKey([string]$product, [string]$id, [int]$hint = -1) {
    # The plain-text key already in the file for this model. Duplicates resolve
    # the same way as everywhere else, so the key belongs to the same entry an
    # edit would land on. $hint is the entry's position in the file array and
    # wins when the entry there still carries the same id - that is what keeps a
    # "test" click on the visible card from testing the hidden twin's key.
    #
    # Returns '' for an ENCRYPTED key, and the order below is load-bearing:
    # Test-WbEncrypted decides by looking for an "envelope" property, so it has
    # to receive the RAW value. Casting to [string] first turned the envelope
    # object into "@{envelope=...}" - a string, which Test-WbEncrypted then
    # correctly reported as "not encrypted" - and that text was sent to the
    # endpoint as the API key. Check first, convert only after.
    if (-not $id) { return '' }
    $raw = Get-ModelsRaw $product
    if (-not $raw.valid) { return '' }
    $idx = Find-ModelEntryIndex $raw.items $id $hint
    if ($idx -lt 0) { return '' }
    $rawKey = Get-ModelProp $raw.items[$idx] 'apiKey'
    if ($null -eq $rawKey) { return '' }
    if (Test-WbEncrypted $rawKey) { return '' }
    $stored = [string]$rawKey
    if ($stored) { return $stored }
    return ''
}

function Test-WbEncrypted($v) {
    # The client can store apiKey as an encrypted envelope when at-rest
    # protection is on. Indexing such a value would deep-copy its guts and
    # re-emit them as plain JSON, so it has to be handed back verbatim.
    if ($null -eq $v) { return $false }
    if ($v -is [string]) { return $false }
    if ($v -is [array]) { return $false }
    if ($v -is [ValueType]) { return $false }
    try { return ($null -ne $v.PSObject.Properties['envelope']) } catch { return $false }
}

function To-ItemArray($v) {
    # Normalise anything into a real array of items. Two traps here:
    #   * @(...) on a value that is already an array nests it one level deeper;
    #   * returning a PowerShell array from a function unrolls it, so a
    #     one-element array arrives as the bare element.
    # The leading comma in the return defeats that unrolling, so the caller
    # always gets an array back. Callers that only want a count can use
    # (To-ItemArray $v).Count - the returned array is a real Object[].
    if ($null -eq $v) { return ,@() }
    if ($v -is [string] -or $v -is [ValueType]) { return ,@($v) }
    if ($v -is [System.Collections.IEnumerable]) {
        $tmp = New-Object System.Collections.Generic.List[object]
        foreach ($e in $v) { $tmp.Add($e) }
        return ,$tmp.ToArray()
    }
    return ,@($v)
}

# Hiding works by RENAMING the id key, not by changing its value:
#   normal: { "id": "foo", ... }
#   hidden: { "-id": "foo", ... }
#
# The client keeps only entries where the expression !!t.id is true, so a
# missing id key makes it drop the entry silently while every other field is
# left untouched. Changing the VALUE instead ("id": "-foo") does NOT work:
# "-foo" is a non-empty string, so the entry survives and simply shows up as a
# model called "-foo". That is the difference between "gone from the client"
# and "still there under a weird name".
$script:HiddenIdKey = '-id'

function Test-PropsHasKey($entry, [string]$name) {
    # Two entry shapes reach these helpers: an object straight out of
    # ConvertFrom-Json (properties surface via PSObject.Properties) and an
    # OrderedDictionary built by New-ModelsProps (whose keys do NOT show up
    # there - PSObject.Properties['id'] is null on a dictionary). Check both,
    # otherwise a lookup silently misses every entry on one of the two paths.
    if ($null -eq $entry) { return $false }
    if ($entry -is [System.Collections.Specialized.OrderedDictionary]) {
        return $entry.Contains($name)
    }
    return ($null -ne $entry.PSObject.Properties[$name])
}

function Get-ModelKey($entry) {
    # The id used for display and for finding the entry. A hidden entry keeps
    # its id under the "-id" key, so both spellings resolve to the same key -
    # which is why a hidden entry can still be edited, deleted and unhidden.
    if ($null -eq $entry) { return '' }
    if ($entry -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($entry.Contains('id')) { return [string]$entry['id'] }
        if ($entry.Contains($script:HiddenIdKey)) { return [string]$entry[$script:HiddenIdKey] }
        return ''
    }
    $p = $entry.PSObject.Properties['id']
    if ($null -ne $p) { return [string]$p.Value }
    $p = $entry.PSObject.Properties[$script:HiddenIdKey]
    if ($null -ne $p) { return [string]$p.Value }
    return ''
}

function Test-ModelArchived($entry) {
    # Hidden means: no "id" key, but a "-id" key holding the value.
    if ($null -eq $entry) { return $false }
    if (Test-PropsHasKey $entry 'id') { return $false }
    return (Test-PropsHasKey $entry $script:HiddenIdKey)
}

function Set-ModelHiddenKey($props, [bool]$hide, [string]$id) {
    # Swap which of the two keys holds the id. The key ORDER is what the client
    # walks, so the marker is put where "id" used to sit - otherwise a hidden
    # entry would come back with its id moved to the end of the object.
    $names = @($props.Keys)
    $pos = $names.Count
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ($names[$i] -eq 'id' -or $names[$i] -eq $script:HiddenIdKey) { $pos = $i; break }
    }
    $rebuilt = New-Object 'System.Collections.Specialized.OrderedDictionary'
    $placed = $false
    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]
        if ($n -eq 'id' -or $n -eq $script:HiddenIdKey) { continue }
        if ($i -gt $pos -and -not $placed) {
            $rebuilt[$(if ($hide) { $script:HiddenIdKey } else { 'id' })] = $id
            $placed = $true
        }
        $rebuilt[$n] = $props[$n]
    }
    if (-not $placed) {
        $rebuilt[$(if ($hide) { $script:HiddenIdKey } else { 'id' })] = $id
    }
    return $rebuilt
}

function Get-ModelProp($entry, [string]$name) {
    # Value of one property, or $null when the field is not present at all.
    # "absent" and "present but null" are different here: absent means leave
    # whatever the file already has alone.
    if ($null -eq $entry) { return $null }
    $p = $entry.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-ModelProp($entry, [string]$name) {
    if ($null -eq $entry) { return $false }
    return ($null -ne $entry.PSObject.Properties[$name])
}

function ConvertTo-ModelEntry($raw) {
    # Normalised view for the editor. Every field is optional: an entry that
    # only carries id + url still has to round-trip without gaining fields.
    $o = [pscustomobject]@{
        id                 = ''
        name               = ''
        vendor             = ''
        url                = ''
        apiKey             = ''
        apiKeyState        = 'absent'
        supportsToolCall   = $false
        supportsImages     = $false
        supportsReasoning  = $false
        supportsToolCallSet   = $false
        supportsImagesSet     = $false
        supportsReasoningSet  = $false
        maxInputTokens     = 0
        maxOutputTokens    = 0
        temperature        = $null
        useCustomProtocol  = $false
        useCustomProtocolSet = $false
        defaultEffort      = ''
        supportedEfforts   = @()
        hidden             = $false
        canDisableThinking    = $true
        canDisableThinkingSet = $false
        icon               = ''
        rawId              = ''
    }
    if ($null -eq $raw) { return $o }

    # The id is read from whichever key holds it ("id" or the hidden "-id"),
    # so a hidden entry still presents its real id to the editor.
    $o.id = (Get-ModelKey $raw)
    $o.hidden = (Test-ModelArchived $raw)
    $o.rawId = $o.id
    if (Test-ModelProp $raw 'name')   { $o.name   = [string](Get-ModelProp $raw 'name') }
    if (Test-ModelProp $raw 'vendor') { $o.vendor = [string](Get-ModelProp $raw 'vendor') }
    if (Test-ModelProp $raw 'url')    { $o.url    = [string](Get-ModelProp $raw 'url') }
    # The client picks which icon to draw from this field (iconUrl first, then
    # icon, then guessing by name). Only the value is carried; the viewer decides
    # what to render.
    if (Test-ModelProp $raw 'icon')   { $o.icon   = [string](Get-ModelProp $raw 'icon') }

    if (Test-ModelProp $raw 'apiKey') {
        $k = Get-ModelProp $raw 'apiKey'
        if ($null -ne $k) {
            if (Test-WbEncrypted $k) { $o.apiKeyState = 'encrypted' }
            else { $o.apiKeyState = 'plain'; $o.apiKey = [string]$k }
        }
    }

    $p = Get-ModelProp $raw 'supportsToolCall'
    if ($null -ne $p) { $o.supportsToolCall = [bool]$p; $o.supportsToolCallSet = $true }
    $p = Get-ModelProp $raw 'supportsImages'
    if ($null -ne $p) { $o.supportsImages = [bool]$p; $o.supportsImagesSet = $true }
    $p = Get-ModelProp $raw 'supportsReasoning'
    if ($null -ne $p) { $o.supportsReasoning = [bool]$p; $o.supportsReasoningSet = $true }

    $p = Get-ModelProp $raw 'maxInputTokens'
    if ($null -ne $p) { $o.maxInputTokens = [long]$p }
    $p = Get-ModelProp $raw 'maxOutputTokens'
    if ($null -ne $p) { $o.maxOutputTokens = [long]$p }
    $p = Get-ModelProp $raw 'temperature'
    if ($null -ne $p) { $o.temperature = [double]$p }

    $p = Get-ModelProp $raw 'useCustomProtocol'
    if ($null -ne $p) { $o.useCustomProtocol = [bool]$p; $o.useCustomProtocolSet = $true }

    if (Test-ModelProp $raw 'reasoning') {
        $r = Get-ModelProp $raw 'reasoning'
        if ($null -ne $r) {
            $d = Get-ModelProp $r 'defaultEffort'
            if ($null -ne $d) { $o.defaultEffort = [string]$d }
            if (Test-ModelProp $r 'supportedEfforts') {
                $list = New-Object System.Collections.Generic.List[string]
                foreach ($e in (To-ItemArray (Get-ModelProp $r 'supportedEfforts'))) {
                    if ($null -ne $e) { $list.Add([string]$e) }
                }
                $o.supportedEfforts = $list.ToArray()
            }
            # canDisableThinking=false is how the client records "thinking may
            # not be turned off". The editor shows that as the default-effort
            # "off" option, so it has to survive a read/write round trip.
            $cd = Get-ModelProp $r 'canDisableThinking'
            if ($null -ne $cd) { $o.canDisableThinking = [bool]$cd; $o.canDisableThinkingSet = $true }
        }
    }
    return $o
}

function Get-ModelsList([string]$product) {
    $raw = Get-ModelsRaw $product
    if (-not $raw.valid) {
        return [pscustomobject]@{
            ok      = $false
            code    = $raw.error
            path    = $raw.path
            exists  = $raw.exists
            models  = @()
            count   = 0
        }
    }
    $arr = $raw.items
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    for ($ai = 0; $ai -lt $arr.Count; $ai++) {
        $m = $arr[$ai]
        if ($null -eq $m) { continue }
        # An entry has to be an object. A stray string or number in the array
        # would make every property lookup below meaningless.
        if (-not ($m -is [psobject]) -or $m -is [string] -or $m -is [ValueType]) { continue }
        # The group marker (title holder) is bookkeeping, not a model: it must
        # never be listed, counted, or offered for editing.
        if (Test-GroupMarker $m) { continue }
        $e = ConvertTo-ModelEntry $m
        $dup = $false
        # Duplicates are judged on the effective id, so a hidden copy of an id
        # still counts as a clash with its visible twin: the client would only
        # ever see one of them after unhiding.
        if ($e.id) {
            if ($seen.ContainsKey($e.id)) { $dup = $true } else { $seen[$e.id] = $true }
        }
        $e = [pscustomobject]@{
            id = $e.id; name = $e.name; vendor = $e.vendor; url = $e.url
            icon = $e.icon
            # Position in the models.json array. An id alone cannot address one
            # entry when a visible copy and a hidden twin share it, which is the
            # normal state after a repeated import: the user clicks the hidden
            # card and an id-only lookup lands on the visible one. The UI sends
            # this back, and the server only trusts it when the entry sitting at
            # that position still carries the same effective id.
            index = $ai
            rawId = $e.rawId
            apiKey = $e.apiKey; apiKeyState = $e.apiKeyState
            supportsToolCall = $e.supportsToolCall; supportsImages = $e.supportsImages
            supportsReasoning = $e.supportsReasoning
            supportsToolCallSet = $e.supportsToolCallSet; supportsImagesSet = $e.supportsImagesSet
            supportsReasoningSet = $e.supportsReasoningSet
            maxInputTokens = $e.maxInputTokens; maxOutputTokens = $e.maxOutputTokens
            temperature = $e.temperature
            useCustomProtocol = $e.useCustomProtocol; useCustomProtocolSet = $e.useCustomProtocolSet
            defaultEffort = $e.defaultEffort; supportedEfforts = @($e.supportedEfforts)
            disabled = $e.disabled; disabledSet = $e.disabledSet
            canDisableThinking = $e.canDisableThinking; canDisableThinkingSet = $e.canDisableThinkingSet
            hidden = $e.hidden
            fields = @($m.PSObject.Properties.Name)
            duplicate = $dup
        }
        $list.Add($e)
    }
    return [pscustomobject]@{
        ok     = $true
        path   = $raw.path
        exists = $raw.exists
        shape  = $raw.shape
        models = $list.ToArray()
        count  = $list.Count
    }
}

function ConvertTo-ModelsText($models) {
    # Serialises the entry array. ConvertTo-Json cannot be used here:
    #   * a one-element array comes back as a bare object, not an array;
    #   * it escapes < > & as \u003c etc., so editing one model would rewrite
    #     every unrelated string in the file;
    #   * its key order follows the object, not the file.
    # So the JSON is written by hand, in the order the entries already carry.
    $body = New-Object System.Text.StringBuilder
    [void]$body.Append("[")
    for ($i = 0; $i -lt $models.Count; $i++) {
        if ($i -gt 0) { [void]$body.Append(",") }
        # Entries sit one level in, so their closing brace sits at column 2 and
        # their members at column 4 - the same layout the file already has.
        [void]$body.Append("`n  ")
        [void]$body.Append((ConvertTo-JsonObject $models[$i] 2))
    }
    [void]$body.Append("`n]")
    return $body.ToString()
}

function ConvertTo-ModelsDocument($models, [string]$shape, $wrapper) {
    # Re-emit the whole file. In the wrapper form every key other than "models"
    # is kept exactly as it was, so only the model list changes.
    if ($shape -ne 'object' -or $null -eq $wrapper) {
        return (ConvertTo-ModelsText $models) + "`n"
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{")
    $first = $true
    $sawModels = $false
    foreach ($p in $wrapper.PSObject.Properties) {
        if (-not $first) { [void]$sb.Append(",") }
        $first = $false
        [void]$sb.Append("`n  ")
        [void]$sb.Append((ConvertTo-JsonString $p.Name))
        [void]$sb.Append(": ")
        if ($p.Name -eq 'models') {
            $sawModels = $true
            # Indent the array two columns deeper: it is the value of "models".
            [void]$sb.Append((((ConvertTo-ModelsText $models).Replace("`n", "`n  ")).TrimStart()))
        } else {
            [void]$sb.Append((ConvertTo-JsonValue $p.Value 2))
        }
    }
    if (-not $sawModels) {
        if (-not $first) { [void]$sb.Append(",") }
        [void]$sb.Append("`n  `"models`": ")
        [void]$sb.Append((((ConvertTo-ModelsText $models).Replace("`n", "`n  ")).TrimStart()))
    }
    [void]$sb.Append("`n}`n")
    return $sb.ToString()
}

function ConvertTo-JsonObject($props, [int]$closeIndent) {
    # $closeIndent is the column the closing brace sits in. Members sit two
    # columns further in, and so does the closing brace of every nested value -
    # that is what keeps the output looking like the file the user already has
    # instead of a reflowed version of it.
    $names = @($props.Keys)
    if ($names.Count -eq 0) { return '{}' }
    $inner = New-Object System.Text.StringBuilder
    $pad = ' ' * ($closeIndent + 2)
    for ($j = 0; $j -lt $names.Count; $j++) {
        $n = $names[$j]
        if ($j -gt 0) { [void]$inner.Append(",") }
        [void]$inner.Append("`n" + $pad)
        [void]$inner.Append((ConvertTo-JsonString ([string]$n)))
        [void]$inner.Append(": ")
        [void]$inner.Append((ConvertTo-JsonValue $props[$n] ($closeIndent + 2)))
    }
    return ('{' + $inner.ToString() + "`n" + (' ' * $closeIndent) + '}')
}

function ConvertTo-JsonValue($v, [int]$indent) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single]) {
        # InvariantCulture: on a comma-decimal locale "0.7" would otherwise be
        # written as "0,7" and the JSON would not parse.
        return ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($v -is [string]) { return (ConvertTo-JsonString $v) }
    if ($v -is [System.Collections.IDictionary]) {
        $inner = New-Object System.Text.StringBuilder
        $keys = @($v.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            if ($i -gt 0) { [void]$inner.Append(",") }
            [void]$inner.Append("`n" + (' ' * ($indent + 2)))
            [void]$inner.Append((ConvertTo-JsonString ([string]$keys[$i])))
            [void]$inner.Append(": ")
            [void]$inner.Append((ConvertTo-JsonValue $v[$keys[$i]] ($indent + 2)))
        }
        if ($keys.Count -eq 0) { return '{}' }
        return ('{' + $inner.ToString() + "`n" + (' ' * $indent) + '}')
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $items = To-ItemArray $v
        if ($items.Count -eq 0) { return '[]' }
        $inner = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -gt 0) { [void]$inner.Append(",") }
            [void]$inner.Append("`n" + (' ' * ($indent + 2)))
            [void]$inner.Append((ConvertTo-JsonValue $items[$i] ($indent + 2)))
        }
        return ('[' + $inner.ToString() + "`n" + (' ' * $indent) + ']')
    }
    # PSCustomObject from ConvertFrom-Json, and anything else object-like.
    try {
        $props = New-ModelsProps $v
        return (ConvertTo-JsonObject $props $indent)
    } catch { }
    return (ConvertTo-JsonString ([string]$v))
}

function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        # An if/elseif chain, NOT `switch (...) { ... continue }`.
        # `continue` inside a switch only skips to the end of THAT switch - it
        # does not skip the rest of the foreach body. Written as a switch, every
        # escaped character fell through to the code below and got a SECOND
        # escape appended: `"` became `\""` (which closes the JSON string early)
        # and `\` became `\\\`. Verified: a value containing a double quote or a
        # backslash produced a models.json that ConvertFrom-Json refuses, so
        # every save/hide/delete/repair threw models_serialize_failed and the
        # file could not be written at all. Newlines gained one extra escape per
        # save, which was silent.
        if     ($c -eq 0x22) { [void]$sb.Append('\"') }
        elseif ($c -eq 0x5C) { [void]$sb.Append('\\') }
        elseif ($c -eq 0x08) { [void]$sb.Append('\b') }
        elseif ($c -eq 0x0C) { [void]$sb.Append('\f') }
        elseif ($c -eq 0x0A) { [void]$sb.Append('\n') }
        elseif ($c -eq 0x0D) { [void]$sb.Append('\r') }
        elseif ($c -eq 0x09) { [void]$sb.Append('\t') }
        elseif ($c -lt 32)   { [void]$sb.Append('\u' + $c.ToString('x4')) }
        else                 { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Save-ModelsSnapshot([string]$product, [string]$text) {
    # One copy per write, pruned to the newest few. The client reloads this file
    # on change, and a bad write means every custom model silently disappears,
    # so a rollback point has to exist before the file is touched.
    try {
        $dir = Join-Path $DataDir 'models-snapshots'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stem = ($product -replace '[^A-Za-z0-9\-]', '_')
        # Name by content hash, not by clock: several edits inside one second
        # would otherwise collide and overwrite each other, so the state just
        # before a given write could be lost.
        $sha = [Security.Cryptography.SHA1]::Create()
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').Substring(0, 10)
        $sha.Dispose()
        $leaf = $stem + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $hash + '.json'
        $target = Join-Path $dir $leaf
        if (-not (Test-Path -LiteralPath $target)) {
            [IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
        # Keep the newest 20 for this edition, drop the rest.
        $mine = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name.StartsWith($stem + '-') } |
                  Sort-Object LastWriteTime -Descending)
        if ($mine.Count -gt 20) {
            foreach ($f in $mine[20..($mine.Count - 1)]) {
                try { [IO.File]::Delete($f.FullName) } catch { }
            }
        }
    } catch { }
}

function Write-ModelsText([string]$path, [string]$text) {
    # Write to a sibling temp file, verify it parses, then swap it in. A crash
    # or a full disk therefore leaves the original file intact instead of a
    # half-written one - and a half-written one is exactly what makes the
    # client drop every custom model without saying anything.
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
    $tmp = $path + '.keeper-tmp'
    $bak = $path + '.keeper-bak'
    $fs = $null
    try {
        $fs = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
        $fs.Close()
        $fs = $null
        # Re-read from disk and parse: proves what landed is valid JSON.
        if (-not (ConvertFrom-ModelsText ([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8))).ok) {
            throw 'models_serialize_failed'
        }
        if (Test-Path -LiteralPath $path) {
            # File.Replace wants a real backup path. Passing $null throws
            # "the path is not of a legal form" on PowerShell 5.1.
            [IO.File]::Replace($tmp, $path, $bak)
        } else {
            [IO.File]::Move($tmp, $path)
        }
    } finally {
        if ($fs) { try { $fs.Close() } catch { } }
        if (Test-Path -LiteralPath $tmp) { try { [IO.File]::Delete($tmp) } catch { } }
        if (Test-Path -LiteralPath $bak) { try { [IO.File]::Delete($bak) } catch { } }
    }
}

function Test-ReservedModelId([string]$id) {
    # The group-title marker's id is reserved: it is bookkeeping the UI never
    # shows, so no user-facing operation may create, edit or delete it.
    return ([string]$id -eq $script:GroupMarkerId)
}

function Save-ModelEntry([string]$product, [string]$originalId, $patch, [bool]$create, [int]$hint = -1, [bool]$NoSnapshot = $false) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    if (-not $create -and (Test-ReservedModelId $originalId)) { throw 'model_not_found' }
    $raw = Get-ModelsRaw $product
    if ($raw.exists -and -not $raw.valid) { throw $raw.error }
    if (-not $raw.exists) { throw 'models_missing' }

    $arr = $raw.items

    # Locate the entry being edited. Editing an entry that vanished (the user
    # changed the file in the client meanwhile) fails loudly instead of
    # appending a second copy under the same id. Lookup is by effective id, so
    # both "foo" and "-foo" (hidden) are found by "foo".
    #
    # $hint is the card's array position and wins when still valid, so acting on
    # a hidden duplicate touches that duplicate rather than its visible twin.
    # See Find-ModelEntryIndex.
    $idx = -1
    if (-not $create) {
        $idx = Find-ModelEntryIndex $arr $originalId $hint
        if ($idx -lt 0) { throw 'model_not_found' }
    }

    # Start from the existing entry so unknown fields survive the edit.
    $props = New-Object 'System.Collections.Specialized.OrderedDictionary'
    if ($idx -ge 0) { $props = New-ModelsProps $arr[$idx] }

    # Hiding is a change to the id itself, so it is handled before the generic
    # field loop below. A patch that does not mention "hidden" must leave the
    # entry exactly as it was: editing the name of a hidden entry should not
    # quietly bring it back into the client's list.
    $wantHidden = $false
    if ($idx -ge 0) { $wantHidden = Test-ModelArchived $arr[$idx] }
    if ($null -ne $patch.PSObject.Properties['hidden']) {
        $wantHidden = [bool]$patch.hidden
    }

    foreach ($p in $patch.PSObject.Properties) {
        $n = $p.Name
        if ($n -eq 'fields' -or $n -eq 'duplicate' -or $n -eq 'raw') { continue }
        if ($n -eq 'hidden' -or $n -eq 'rawId') { continue }
        # The hidden spelling of the id is never a field to copy; the id is
        # written back by Set-ModelHiddenKey.
        if ($n -eq $script:HiddenIdKey) { continue }
        if ($n.EndsWith('Set')) { continue }
        if ($n -eq 'apiKeyState') { continue }
        # supportedEfforts / defaultEffort belong INSIDE the reasoning object,
        # which is rebuilt further down. Letting them through here also wrote
        # them at the entry's top level, so every save added two stray keys that
        # ConvertTo-ModelEntry never reads back (verified).
        if ($n -eq 'supportedEfforts' -or $n -eq 'defaultEffort') { continue }
        $v = $p.Value
        # Whether an empty value drops the field or is kept as an empty string.
        #
        # url and apiKey are the fields the model needs to be usable at all, so
        # they are kept in the file even when emptied: an empty value stays
        # visible ("this row is not configured yet") instead of vanishing, and
        # the viewer keeps rendering a text box for it. The client treats ""
        # and missing the same way internally, so this changes nothing for the
        # client - it only stops the field from silently disappearing.
        #
        # Everything else (description, vendor, reasoning, and the rest) is a
        # real "remove this key" when emptied, because for those an empty string
        # would be written into the file as a meaningless value.
        $keepWhenEmpty = ($n -eq 'url' -or $n -eq 'apiKey')
        if ($null -eq $v) {
            if ($props.Contains($n)) { $props.Remove($n) }
            continue
        }
        if ($v -is [string]) {
            if ([string]$v -eq '') {
                if ($keepWhenEmpty) { $props[$n] = ''; continue }
                if ($n -ne 'name' -and $n -ne 'vendor') {
                    if ($props.Contains($n)) { $props.Remove($n) }
                    continue
                }
            }
        } elseif ($v -is [System.Collections.IEnumerable]) {
            # An emptied list means "drop the field".
            if ((To-ItemArray $v).Count -eq 0) {
                if ($props.Contains($n)) { $props.Remove($n) }
                continue
            }
        }
        # These three are numbers in models.json. A caller that hands them over
        # as strings ("128000") would otherwise be written verbatim - quoted,
        # which is a different JSON type from what the batch importer writes -
        # and the file ends up mixing "128000" and 128000 for the same field.
        # Coerce here rather than trusting every caller to get it right.
        # InvariantCulture for the same reason ConvertTo-JsonValue uses it: on a
        # comma-decimal locale "128.5" must not be read as 1285.
        if ($n -eq 'maxInputTokens' -or $n -eq 'maxOutputTokens' -or $n -eq 'temperature') {
            $num = 0.0
            $ci = [Globalization.CultureInfo]::InvariantCulture
            $sty = [Globalization.NumberStyles]::Float
            if ([double]::TryParse(([string]$v), $sty, $ci, [ref]$num)) {
                if ($n -eq 'temperature') { $v = [double]$num }
                else { $v = [long][Math]::Round($num) }
            }
        }
        $props[$n] = $v
    }

    # reasoning is rebuilt only when the editor actually touched it.
    if ($null -ne $patch.PSObject.Properties['defaultEffort'] -or
        $null -ne $patch.PSObject.Properties['supportedEfforts'] -or
        $null -ne $patch.PSObject.Properties['canDisableThinking']) {
        # Do NOT pipe To-ItemArray's result. It returns a comma-wrapped array to
        # survive the pipeline unrolling of the *function* return, so piping it
        # hands the whole array over as ONE object: Where-Object then sees a
        # string[] and ([string]$_) flattens it to "low high max", writing a
        # single bogus effort instead of the three real ones. That is exactly the
        # bug where a multi-select came back as only the default level.
        $efforts = New-Object System.Collections.Generic.List[string]
        foreach ($ev in (To-ItemArray $patch.supportedEfforts)) {
            $s = ([string]$ev).Trim()
            if ($s) { $efforts.Add($s) }
        }
        $def = [string]$patch.defaultEffort
        # canDisableThinking=false is the editor's "off (no thinking)" option,
        # which is not one of the effort levels: it lives inside the reasoning
        # object rather than in supportedEfforts.
        #
        # The editor deliberately does NOT send this field ("the value already in
        # the file stays", per the UI and the docs). So when the patch is silent
        # the EXISTING value has to be carried over - this block rebuilds the
        # whole reasoning object and replaces the old one, so anything not put
        # back here is lost. Without the else-branch below, a stored
        # canDisableThinking=false was silently deleted on every save, and the
        # client then let the user turn thinking off for a model where it must
        # not be turned off.
        $canDis = $true
        $canDisSet = $false
        if ($null -ne $patch.PSObject.Properties['canDisableThinking']) {
            $canDis = [bool]$patch.canDisableThinking
            $canDisSet = $true
        } elseif ($props.Contains('reasoning') -and $null -ne $props['reasoning']) {
            $old = Get-ModelProp $props['reasoning'] 'canDisableThinking'
            if ($null -ne $old) {
                $canDis = [bool]$old
                $canDisSet = $true
            }
        }
        if ($efforts.Count -gt 0 -or $def -or ($canDisSet -and -not $canDis)) {
            $r = New-Object 'System.Collections.Specialized.OrderedDictionary'
            if ($def) { $r['defaultEffort'] = $def }
            if ($efforts.Count -gt 0) { $r['supportedEfforts'] = @($efforts) }
            if ($canDisSet -and -not $canDis) { $r['canDisableThinking'] = $false }
            if ($props.Contains('reasoning')) { $props.Remove('reasoning') }
            $props['reasoning'] = $r
        } else {
            if ($props.Contains('reasoning')) { $props.Remove('reasoning') }
        }
    }

    # The id, from whichever key currently holds it. A patch that omits id keeps
    # the one the entry already had.
    $newId = ''
    try { $newId = (Get-ModelKey $props).Trim() } catch { $newId = '' }
    if (-not $newId -and $props.Contains('id')) { $newId = ([string]$props['id']).Trim() }
    $newId = $newId.TrimStart('-')
    if (-not $newId) { throw 'model_id_required' }
    # No character-set rule here on purpose. The client accepts any non-empty id
    # (real ones look like "glm-5.2" or "qwen3.8-max"), so narrowing the charset
    # would reject valid ids while doing nothing about a short one like "33" -
    # that is a typo, not an illegal character, and only the user can tell.
    #
    # A same-id entry is NOT rejected any more: importing a model that is
    # already there is a normal thing to do, and the client resolves a model by
    # its id alone. The invariant this program maintains is "at most one
    # VISIBLE entry per id" - see the sibling pass below, which hides any other
    # same-id entry whenever the saved one is visible. That makes the result
    # unambiguous without depending on which end of the list the client reads.

    # Finally put the id back under the right key. Hiding swaps "id" for "-id";
    # that missing "id" key is the whole mechanism (see Get-ModelKey).
    $props = Set-ModelHiddenKey $props $wantHidden $newId
    $storedId = $newId

    $list = New-Object System.Collections.Generic.List[object]
    if ($idx -ge 0) {
        for ($i = 0; $i -lt $arr.Count; $i++) {
            if ($i -eq $idx) { $list.Add($props) } elseif ($null -ne $arr[$i]) { $list.Add((New-ModelsProps $arr[$i])) }
        }
    } else {
        foreach ($m in $arr) { if ($null -ne $m) { $list.Add((New-ModelsProps $m)) } }
        $list.Add($props)
    }

    # Enforce "at most one visible entry per id". The entry just saved keeps the
    # visible slot; every other same-id entry that is still visible gets hidden
    # (id -> "-id"), which leaves all of its fields intact and is reversible
    # from the model list. Done in place on $list so nothing else changes.
    $hiddenSiblings = New-Object System.Collections.Generic.List[string]
    if (-not $wantHidden) {
        $savedPos = $(if ($idx -ge 0) { $idx } else { $list.Count - 1 })
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($i -eq $savedPos) { continue }
            $e = $list[$i]
            if ($null -eq $e) { continue }
            if ((Get-ModelKey $e) -ne $newId) { continue }
            if (Test-ModelArchived $e) { continue }
            $list[$i] = Set-ModelHiddenKey $e $true $newId
            $hiddenSiblings.Add($newId)
        }
    }

    $text = ConvertTo-ModelsDocument $list $raw.shape $raw.wrapper
    if (-not (ConvertFrom-ModelsText $text).ok) { throw 'models_serialize_failed' }
    # $NoSnapshot is for the batch importer: it saves one entry at a time, and
    # Save-ModelsSnapshot keeps only the newest 20 files. A batch of more than
    # 20 would therefore push out the very snapshot of the pre-import file that
    # is supposed to be the way back. The batch takes ONE snapshot before its
    # loop instead, and turns this off for every item.
    if (-not $NoSnapshot) { Save-ModelsSnapshot $product $raw.text }
    Write-ModelsText $raw.path $text
    Write-Log ("models saved: {0} id={1} stored={2} create={3} hidSiblings={4}" -f `
               $product, $newId, $storedId, $create, $hiddenSiblings.Count)
    $after = Get-ModelsList $product
    return [pscustomobject]@{
        ok             = $true
        product        = $product
        id             = $newId
        storedId       = $storedId
        hidden         = [bool]$wantHidden
        hiddenSiblings = $hiddenSiblings.ToArray()
        count          = $after.count
        models         = $after.models
        path           = $after.path
    }
}

function Repair-ModelDuplicates([string]$product) {
    # Enforce the invariant the client itself relies on: for any id, exactly one
    # entry may be VISIBLE. The client resolves a model by id alone, so when two
    # visible entries share an id they collide.
    #
    # Which one survives? The LAST visible one, per an end-to-end experiment
    # against the real workbuddy binary (10 same-id entries -> only the 10th
    # showed up in /v1/models). Note this contradicts a plain reading of
    # `Array.find` in model-resolver (first match); the merge path
    # (mergeModelsById builds a Map with i.set) is what decides in practice, and
    # the experiment is the authority. Keep LAST; do not "fix" this by reading
    # find() alone.
    #
    # Hidden means: the "id" key is renamed to "-id". The client validates
    # entries with isValidLocalCustomModel, which requires `typeof e.id ===
    # 'string' && e.id.trim() !== ''`, so a renamed entry is dropped from the
    # list entirely - while all of its fields stay in the file and can be
    # restored later. Nothing is deleted.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $raw = Get-ModelsRaw $product
    if (-not $raw.exists) { throw 'models_missing' }
    if (-not $raw.valid) { throw $raw.error }

    $arr = $raw.items
    # Last visible index per id. A hidden entry does not compete: it is already
    # out of the client's list, so it must not shadow a visible one.
    $lastVisible = @{}
    for ($i = 0; $i -lt $arr.Count; $i++) {
        $e = $arr[$i]
        if ($null -eq $e) { continue }
        if (Test-ModelArchived $e) { continue }
        $k = (Get-ModelKey $e)
        if (-not $k) { continue }
        $lastVisible[$k] = $i
    }

    $list = New-Object System.Collections.Generic.List[object]
    $hidden = New-Object System.Collections.Generic.List[string]
    $hiddenIds = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $arr.Count; $i++) {
        $e = $arr[$i]
        if ($null -eq $e) { continue }
        $props = New-ModelsProps $e
        if (-not (Test-ModelArchived $e)) {
            $k = (Get-ModelKey $e)
            if ($k -and $lastVisible.ContainsKey($k) -and $lastVisible[$k] -ne $i) {
                # An earlier twin of a later visible entry: hide this one.
                $props = Set-ModelHiddenKey $props $true $k
                $hidden.Add($k)
                $hiddenIds.Add([pscustomobject]@{ id = $k; name = [string](Get-ModelProp $e 'name') })
            }
        }
        $list.Add($props)
    }

    if ($hidden.Count -eq 0) {
        return [pscustomobject]@{
            ok      = $true
            product = $product
            changed = $false
            hidden  = @()
            details = @()
            count   = (Get-ModelsList $product).count
        }
    }

    $text = ConvertTo-ModelsDocument $list $raw.shape $raw.wrapper
    if (-not (ConvertFrom-ModelsText $text).ok) { throw 'models_serialize_failed' }
    Save-ModelsSnapshot $product $raw.text
    Write-ModelsText $raw.path $text
    Write-Log ("models repaired: {0} hid={1}" -f $product, $hidden.Count)

    $after = Get-ModelsList $product
    return [pscustomobject]@{
        ok      = $true
        product = $product
        changed = $true
        hidden  = $hidden.ToArray()
        details = $hiddenIds.ToArray()
        count   = $after.count
        models  = $after.models
    }
}

function Remove-ModelEntry([string]$product, [string]$id, [int]$hint = -1) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    if (-not $id) { throw 'model_id_required' }
    # The group-title marker is not a model; deleting it would drop the group's
    # title. Report it the same way as any other unknown id.
    if (Test-ReservedModelId $id) { throw 'model_not_found' }
    $raw = Get-ModelsRaw $product
    if (-not $raw.exists) { throw 'models_missing' }
    if (-not $raw.valid) { throw $raw.error }

    $arr = $raw.items
    # Delete works by effective id so a hidden entry can be removed without
    # unhiding it first. $hint carries the card's array position, which is what
    # makes deleting a HIDDEN card remove that hidden entry - with an id-only
    # lookup the visible twin always won, so pressing delete on the hidden card
    # deleted the model the user was actually using (verified).
    $idx = Find-ModelEntryIndex $arr $id $hint
    if ($idx -lt 0) { throw 'model_not_found' }

    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $arr.Count; $i++) {
        if ($i -eq $idx) { continue }
        if ($null -eq $arr[$i]) { continue }
        $list.Add((New-ModelsProps $arr[$i]))
    }

    $text = ConvertTo-ModelsDocument $list $raw.shape $raw.wrapper
    if (-not (ConvertFrom-ModelsText $text).ok) { throw 'models_serialize_failed' }
    Save-ModelsSnapshot $product $raw.text
    Write-ModelsText $raw.path $text
    Write-Log ("models deleted: {0} id={1}" -f $product, $id)

    $after = Get-ModelsList $product
    return [pscustomobject]@{
        ok      = $true
        product = $product
        id      = $id
        count   = $after.count
        models  = $after.models
        path    = $after.path
    }
}

# --------------------------------------------------------------------------
# model.csv - capability defaults for models the listing does not describe
#
# Lives in the program directory (next to app.ps1), NOT in the edition home:
# it describes how this tool should import models, so it belongs with the tool
# and is shared by both editions.
#
# Columns (the header names are matched loosely - see Get-ModelCsvAliases):
#
#   id,<supportsToolCall>,<supportsImages>,<supportsReasoning>,
#      <supportedEfforts>,<defaultEffort>,<contextLength>,<hidden>,<icon>
#
# The shipped template writes those headers in Chinese; the loader accepts the
# Chinese names, the English property names, and a few obvious shorthands, so a
# hand-edited file is hard to get wrong. See Get-ModelCsvHeaderMap.
#
# id may contain "*" as a wildcard. Lookup order for a given model id is:
#   1. exact id match
#  2. first wildcard match, in file order
#   3. built-in defaults
# The listing's own values always win where it actually reported something.
# --------------------------------------------------------------------------

$script:ModelCsvNames = @{
    Tool   = 'supportsToolCall'
    Images = 'supportsImages'
    Think  = 'supportsReasoning'
    Effort = 'supportedEfforts'
    Default = 'defaultEffort'
    Ctx    = 'maxInputTokens'
    Hidden = 'hidden'
}

function Get-ModelCsvPath() {
    return (Join-Path $ScriptDir 'model.csv')
}

function Get-ModelCsvHeaderMap($header) {
    # Maps a header cell to one canonical column key, or '' to ignore it.
    # Matched on a normalised form so the Chinese header, "supports_tool_call"
    # and "SupportsToolCall" all land on the same column - the file is meant to
    # be hand-edited, so being strict about spelling would only cause silent
    # misreads.
    #
    # Chinese spellings are built from code points because this file must stay
    # pure ASCII (it is read by PowerShell 5.1, which may treat a no-BOM file as
    # ANSI and mangle literal non-ASCII bytes).
    $cId     = [string]([char]0x6A21 + [char]0x578B + [char]0x69) + [char]0x64
    $cTool   = [string]([char]0x652F + [char]0x6301 + [char]0x5DE5 + [char]0x5177)
    $cToolS  = [string]([char]0x5DE5 + [char]0x5177)
    $cImg    = [string]([char]0x652F + [char]0x6301 + [char]0x56FE + [char]0x7247)
    $cImgS   = [string]([char]0x56FE + [char]0x7247)
    $cThink  = [string]([char]0x652F + [char]0x6301 + [char]0x601D + [char]0x8003)
    $cReas   = [string]([char]0x652F + [char]0x6301 + [char]0x63A8 + [char]0x7406)
    $cThinkS = [string]([char]0x601D + [char]0x8003)
    $cEff    = [string]([char]0x63A8 + [char]0x7406 + [char]0x6863 + [char]0x4F4D)
    $cEffS   = [string]([char]0x6863 + [char]0x4F4D)
    $cDef    = [string]([char]0x9ED8 + [char]0x8BA4 + [char]0x6863 + [char]0x4F4D)
    $cCtx    = [string]([char]0x4E0A + [char]0x4E0B + [char]0x6587 + [char]0x957F + [char]0x5EA6)
    $cCtxS   = [string]([char]0x4E0A + [char]0x4E0B + [char]0x6587)
    $cHid    = [string]([char]0x9690 + [char]0x85CF)
    $cHidS   = [string]([char]0x9690 + [char]0x85CF + [char]0x6A21 + [char]0x578B)
    # "tubiao" - the icon column added in v1.6.7
    $cIcon   = [string]([char]0x56FE + [char]0x6807)
    # "shuchu changdu" - the output-length column. The context column only ever
    # fed maxInputTokens, so a listing that reported no output cap left it unset
    # with no way to fill it in. Built from code points to keep this file ASCII.
    $cOut    = [string]([char]0x8F93 + [char]0x51FA + [char]0x957F + [char]0x5EA6)
    $cOutS   = [string]([char]0x8F93 + [char]0x51FA)

    $map = @{}
    for ($i = 0; $i -lt $header.Count; $i++) {
        $h = ([string]$header[$i]).Trim().ToLowerInvariant()
        $h = $h -replace '[\s_\-]', ''
        $key = ''
        if     ($h -eq 'id' -or $h -eq $cId) { $key = 'id' }
        elseif ($h -eq $cTool -or $h -eq $cToolS -or $h -eq 'supportstoolcall' -or $h -eq 'tool') { $key = 'Tool' }
        elseif ($h -eq $cImg -or $h -eq $cImgS -or $h -eq 'supportsimages' -or $h -eq 'image' -or $h -eq 'images') { $key = 'Images' }
        elseif ($h -eq $cThink -or $h -eq $cReas -or $h -eq $cThinkS -or $h -eq 'supportsreasoning' -or $h -eq 'reason') { $key = 'Think' }
        elseif ($h -eq $cEff -or $h -eq $cEffS -or $h -eq 'supportedefforts' -or $h -eq 'effort' -or $h -eq 'efforts') { $key = 'Effort' }
        elseif ($h -eq $cDef -or $h -eq 'defaulteffort') { $key = 'Default' }
        elseif ($h -eq $cCtx -or $h -eq $cCtxS -or $h -eq 'context' -or $h -eq 'contextlength' -or $h -eq 'maxinputtokens') { $key = 'Ctx' }
        elseif ($h -eq $cOut -or $h -eq $cOutS -or $h -eq 'maxoutputtokens' -or $h -eq 'outputlength' -or $h -eq 'output') { $key = 'Out' }
        elseif ($h -eq $cHid -or $h -eq $cHidS -or $h -eq 'hidden') { $key = 'Hidden' }
        elseif ($h -eq $cIcon -or $h -eq 'icon' -or $h -eq 'vendor') { $key = 'Icon' }
        if ($key) { $map[$i] = $key }
    }
    return $map
}

function Import-ModelCsv() {
    # Returns @{ ok; rows; error } where a row is a hashtable of the canonical
    # keys plus 'pattern'. A missing file is not an error: the feature is
    # optional and the defaults apply.
    $out = [pscustomobject]@{ ok = $true; rows = @(); error = ''; path = (Get-ModelCsvPath) }
    $p = $out.path
    if (-not (Test-Path -LiteralPath $p)) { return $out }
    $text = ''
    try { $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
    catch { $out.ok = $false; $out.error = 'csv_unreadable'; return $out }
    if (-not $text.Trim()) { return $out }

    $lines = $text -split "\r?\n"
    $rows = New-Object System.Collections.Generic.List[object]
    $map = $null
    $width = 0
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $t = $line.Trim()
        if (-not $t) { continue }
        # A leading # makes the line a comment, so the shipped template can
        # explain itself without its explanation being parsed as data.
        if ($t.StartsWith('#')) { continue }
        $cells = @(Split-CsvLine $line)
        if ($null -eq $map) {
            $map = Get-ModelCsvHeaderMap $cells
            if (-not $map.ContainsKey(0) -and (([string]$cells[0]).Trim().ToLowerInvariant() -ne 'id')) {
                # No usable header: treat the file as bodiless rather than
                # guessing column order, which would silently fill wrong fields.
                $out.ok = $false; $out.error = 'csv_no_id_column'; return $out
            }
            $map[0] = 'id'
            $width = $cells.Count
            continue
        }
        $row = @{}
        foreach ($k in $map.Keys) {
            if ($k -lt $cells.Count) { $row[$map[$k]] = ([string]$cells[$k]).Trim() }
        }
        $pat = [string]$row['id']
        if (-not $pat) { continue }
        $row['pattern'] = $pat
        $rows.Add($row)
    }
    $out.rows = $rows.ToArray()
    return $out
}

function Split-CsvLine([string]$line) {
    # Minimal RFC4180-ish splitter: enough for hand-written config, and it
    # understands "" inside a quoted cell so a value may contain a comma.
    $cells = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQ = $false
    for ($i = 0; $i -lt $line.Length; $i++) {
        $ch = $line[$i]
        if ($inQ) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $line.Length -and $line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ }
                else { $inQ = $false }
            } else { [void]$sb.Append($ch) }
        } else {
            if ($ch -eq '"') { $inQ = $true }
            elseif ($ch -eq ',') { $cells.Add($sb.ToString()); [void]$sb.Clear() }
            else { [void]$sb.Append($ch) }
        }
    }
    $cells.Add($sb.ToString())
    # Plain array out; callers use @(...) - see Get-ModelProbeUrlCandidates.
    return $cells.ToArray()
}

function Find-ModelCsvRow($rows, [string]$id) {
    # Exact match first, then the first wildcard pattern that matches, in file
    # order. Exact-before-wildcard is the whole point: a specific override has
    # to beat a broad "*" catch-all no matter where it sits in the file.
    if (-not $id) { return $null }
    foreach ($r in $rows) {
        $pat = [string]$r['pattern']
        if (-not $pat) { continue }
        if ($pat.IndexOf('*') -lt 0) {
            if ($pat -eq $id) { return $r }
        }
    }
    foreach ($r in $rows) {
        $pat = [string]$r['pattern']
        if (-not $pat -or $pat.IndexOf('*') -lt 0) { continue }
        if (Test-ModelCsvGlob $pat $id) { return $r }
    }
    # A model id that itself contains "*" is unusual but legal; fall back to a
    # literal comparison against the patterns that had no wildcard.
    return $null
}

function Test-ModelCsvGlob([string]$pattern, [string]$id) {
    if (-not $pattern) { return $false }
    if ($pattern.IndexOf('*') -lt 0) { return ($pattern -eq $id) }
    # Escape everything, then let "*" through as the only wildcard. Anchored so
    # "abc*" does not match "xabc".
    $rx = [regex]::Escape($pattern).Replace('\*', '.*')
    return ([regex]::IsMatch($id, '^' + $rx + '$', [Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function ConvertTo-CsvBool([string]$v, [bool]$fallback) {
    # Accepts the obvious spellings in both languages. Built from code points
    # where Chinese, to keep this file pure ASCII.
    if ($null -eq $v) { return $fallback }
    $s = ([string]$v).Trim().ToLowerInvariant()
    if (-not $s) { return $fallback }
    $yes1 = [string]([char]0x662F)                                    # yes
    $yes2 = [string]([char]0x652F + [char]0x6301)                      # support
    $yes3 = [string]([char]0x5F00)                                     # on
    $yes4 = [string]([char]0x5F00 + [char]0x542F)                      # enabled
    $no1  = [string]([char]0x5426)                                     # no
    $no2  = [string]([char]0x4E0D + [char]0x652F + [char]0x6301)       # unsupported
    $no3  = [string]([char]0x5173)                                     # off
    $no4  = [string]([char]0x5173 + [char]0x95ED)                      # closed/off
    if ($s -in @('1', 'true', 'yes', 'y', 'on', $yes1, $yes2, $yes3, $yes4)) { return $true }
    if ($s -in @('0', 'false', 'no', 'n', 'off', $no1, $no2, $no3, $no4)) { return $false }
    return $fallback
}

function ConvertTo-CsvEfforts([string]$v) {
    # "high|max", "high,max" and the Chinese labels all map to the client's
    # enum. Unknown names are dropped rather than written through, because an
    # effort the client does not know would make the model look broken in its
    # picker.
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $v) { return $out.ToArray() }
    $zhLow   = [string]([char]0x4F4E)
    $zhMid   = [string]([char]0x4E2D)
    $zhHigh  = [string]([char]0x9AD8)
    $zhXHigh = [string]([char]0x8D85 + [char]0x9AD8)
    $zhMax   = [string]([char]0x6781 + [char]0x81F4)
    $known = @{}
    $known[$zhLow] = 'low'; $known['low'] = 'low'
    $known[$zhMid] = 'medium'; $known['medium'] = 'medium'
    $known[$zhHigh] = 'high'; $known['high'] = 'high'
    $known[$zhXHigh] = 'xhigh'; $known['xhigh'] = 'xhigh'
    $known[$zhMax] = 'max'; $known['max'] = 'max'
    $sep = '[|,' + [char]0xFF0C + ';' + [char]0xFF1B + '/\s]+'
    foreach ($part in ($v -split $sep)) {
        $s = $part.Trim()
        if (-not $s) { continue }
        if ($known.ContainsKey($s)) { $out.Add([string]$known[$s]); continue }
        $lc = $s.ToLowerInvariant()
        if ($known.ContainsKey($lc)) { $out.Add([string]$known[$lc]) }
    }
    # Plain array out; callers use @(...).
    return $out.ToArray()
}

function ConvertTo-CsvEffortOne([string]$v) {
    $a = @(ConvertTo-CsvEfforts $v)
    if ($a.Count -gt 0) { return [string]$a[0] }
    return ''
}

function ConvertTo-CsvTokens([string]$v) {
    # Accepts a plain count or a K-suffixed value ("1048k" / "1048K" / "1048576").
    if (-not $v) { return 0 }
    $s = ([string]$v).Trim().ToLowerInvariant()
    if (-not $s) { return 0 }
    $mult = 1
    if ($s.EndsWith('k')) { $mult = 1000; $s = $s.Substring(0, $s.Length - 1).Trim() }
    elseif ($s.EndsWith('m')) { $mult = 1000000; $s = $s.Substring(0, $s.Length - 1).Trim() }
    $n = 0.0
    # Parse with the invariant culture on purpose. [double]::TryParse without it
    # follows the machine's locale, and on a comma-decimal locale "128.5k" would
    # read as 1285 and be written out as 1285000. Everything else in this file
    # that converts a number from text does the same for the same reason.
    if (-not [double]::TryParse($s, [Globalization.NumberStyles]::Float,
                                [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return 0 }
    if ($n -le 0) { return 0 }
    return [long][Math]::Round($n * $mult)
}

function Get-ModelCsvDefaults() {
    # What applies when neither the listing nor model.csv said anything.
    return [pscustomobject]@{
        supportsToolCall  = $true
        supportsImages    = $false
        supportsReasoning = $true
        supportedEfforts  = @('high', 'max')
        defaultEffort     = 'high'
        maxInputTokens    = 0
        maxOutputTokens   = 0
        hidden            = $false
    }
}


# --------------------------------------------------------------------------
# models.json groups ("model file" tabs)
#
# The client only ever reads one file: <edition home>\models.json. Switching
# between model sets therefore works by RENAMING files on disk, never by
# rewriting which path the client looks at (there is no such setting):
#
#   models.json              <- the active group, the only one the client reads
#   models<TITLE>.json       <- every other group, parked until selected
#   models2.json             <- a group whose name is just the number 2
#
# The title goes BEFORE the extension on purpose. Appending it after ".json"
# (models.json<TITLE>) changes the extension, so the parked files stop looking
# like JSON at all - Explorer stops previewing them, editors stop offering JSON
# syntax highlighting, and any tool that globs *.json silently misses them.
# --------------------------------------------------------------------------
# A group's TITLE has to survive the rename, so it is stored INSIDE the file as
# a hidden marker entry sitting at the top of the model list:
#
#   { "-id": "ModelFileName", "name": "<title>", "url": "...", "apiKey": "..." }
#
# "-id" (not "id") makes the client drop it silently, exactly like a hidden
# model, so it is invisible in the client while staying in the file. The id
# value is a fixed sentinel so the marker is recognisable after any rename.
# --------------------------------------------------------------------------
$script:GroupMarkerId = 'ModelFileName'
# "untitled" - spelled in code points because this file must stay pure ASCII.
$script:UntitledZh = [string]([char]0x65E0 + [char]0x6807 + [char]0x9898)

function Test-GroupMarker($entry) {
    if ($null -eq $entry) { return $false }
    if (-not (Test-ModelArchived $entry)) { return $false }
    return ((Get-ModelKey $entry) -eq $script:GroupMarkerId)
}

function New-GroupMarkerProps([string]$title) {
    $d = New-Object 'System.Collections.Specialized.OrderedDictionary'
    $d[$script:HiddenIdKey] = $script:GroupMarkerId
    $d['name'] = [string]$title
    # Sample values, not empty ones: the marker is meant to be a real entry so
    # the client's own validation never has a reason to look twice at it.
    $d['url'] = 'https://example.com/v1/chat/completions'
    $d['apiKey'] = 'sk-...'
    return $d
}

function Test-GroupFile([string]$name) {
    # A parked group is "models<TITLE>.json"; the active one is plain
    # "models.json". Both must match, and our own atomic-write leftovers
    # (models.json.keeper-tmp / .keeper-bak) must not.
    if (-not $name) { return $false }
    if ($name -eq 'models.json') { return $true }
    if (-not $name.StartsWith('models')) { return $false }
    if (-not $name.EndsWith('.json')) { return $false }
    if ($name.EndsWith('.keeper-tmp')) { return $false }
    if ($name.EndsWith('.keeper-bak')) { return $false }
    # "models" + something + ".json"; the middle part is the title.
    if ($name.Length -le ('models'.Length + '.json'.Length)) { return $false }
    return $true
}

function Get-GroupSuffix([string]$file) {
    # The title carried by the FILE NAME, or '' when there is none.
    if (-not $file) { return '' }
    if ($file -eq 'models.json') { return '' }
    if (-not (Test-GroupFile $file)) { return '' }
    $mid = $file.Substring('models'.Length)
    $mid = $mid.Substring(0, $mid.Length - '.json'.Length)
    return $mid
}

function Get-GroupFileName([string]$title) {
    # models.json for no title; "models<title>.json" otherwise. The title goes
    # BEFORE the extension so the parked file keeps looking like JSON.
    if (-not $title) { return 'models.json' }
    return ('models' + $title + '.json')
}

function Get-SafeGroupTitle([string]$title, [string]$fallback) {
    # A title doubles as a file name, so it has to obey Windows' rules: no
    # path separators, no <>:"/\|?*, no control characters, no trailing dot or
    # space (which Windows silently strips, producing a name nobody typed).
    $t = [string]$title
    if ($null -eq $t) { $t = '' }
    $t = [regex]::Replace($t, '[\x00-\x1f<>:"/\\|?*]', '')
    $t = $t.Trim().TrimEnd('.').Trim()
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60).Trim() }
    if (-not $t) { $t = $fallback }
    if (-not $t) { $t = 'untitled' }
    return $t
}

function Get-GroupTitleFromFile([string]$path, [string]$file) {
    # Embedded title wins; otherwise the name after "models.json" is the title;
    # otherwise the file is untitled.
    try {
        if (Test-Path -LiteralPath $path) {
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $parsed = ConvertFrom-ModelsText $text
            if ($parsed.ok) {
                foreach ($e in $parsed.items) {
                    if ($null -eq $e) { continue }
                    if (Test-GroupMarker $e) {
                        $t = ([string](Get-ModelProp $e 'name')).Trim()
                        if ($t) { return $t }
                        break
                    }
                }
            }
        }
    } catch { }
    $s = Get-GroupSuffix $file
    if ($s) { return $s }
    return $script:UntitledZh
}

function Get-UniqueGroupPath([string]$dir, [string]$suffix) {
    # models<title>.json, then <title>2, <title>3 ... until one is free.
    # A title-less group has no parked file at all (it IS models.json), so the
    # caller never asks for one; the fallback name below just keeps the loop
    # from producing a bare "models.json" collision.
    if (-not $suffix) { $suffix = $script:UntitledZh }
    $p = Join-Path $dir (Get-GroupFileName $suffix)
    if (-not (Test-Path -LiteralPath $p)) { return $p }
    for ($i = 2; $i -le 999; $i++) {
        $p = Join-Path $dir (Get-GroupFileName ($suffix + [string]$i))
        if (-not (Test-Path -LiteralPath $p)) { return $p }
    }
    throw 'too_many_groups'
}

function Set-GroupMarkerInFile([string]$product, [string]$path, [string]$title) {
    # Rewrite one group file with its title marker sitting at the very top of
    # the model list, replacing any marker that was there before.
    $parsed = $null
    $oldText = ''
    if (Test-Path -LiteralPath $path) {
        $oldText = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $parsed = ConvertFrom-ModelsText $oldText
    }
    if ($null -eq $parsed) { $parsed = ConvertFrom-ModelsText '[]' }
    if (-not $parsed.ok) { throw 'models_malformed' }

    $list = New-Object System.Collections.Generic.List[object]
    $list.Add((New-GroupMarkerProps $title))
    foreach ($e in $parsed.items) {
        if ($null -eq $e) { continue }
        if (Test-GroupMarker $e) { continue }
        $list.Add((New-ModelsProps $e))
    }
    if ($parsed.shape -eq 'none') { $parsed.shape = 'array' }
    $doc = ConvertTo-ModelsDocument $list $parsed.shape $parsed.wrapper
    if (-not (ConvertFrom-ModelsText $doc).ok) { throw 'models_serialize_failed' }
    if ($oldText) { Save-ModelsSnapshot $product $oldText }
    Write-ModelsText $path $doc
}

function Get-ModelGroups([string]$product) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $dir = Get-EditionHome $product
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $dir)) { return ,$out.ToArray() }
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
               Where-Object { Test-GroupFile $_.Name } |
               Sort-Object Name)
    foreach ($f in $files) {
        $n = $f.Name
        $item = [pscustomobject]@{
            file = $n
            path = $f.FullName
            active = ($n -eq 'models.json')
            title = ''
            loadable = $false
            count = 0
            error = ''
        }
        try { $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) }
        catch { $item.error = 'read_failed'; $out.Add($item); continue }
        if (-not $text.Trim()) { $item.error = 'models_empty'; $out.Add($item); continue }
        $parsed = ConvertFrom-ModelsText $text
        if (-not $parsed.ok) { $item.error = 'models_malformed'; $out.Add($item); continue }
        $item.loadable = $true
        $title = ''
        $cnt = 0
        foreach ($e in $parsed.items) {
            if ($null -eq $e) { continue }
            if (-not ($e -is [psobject]) -or $e -is [string] -or $e -is [ValueType]) { continue }
            if (Test-GroupMarker $e) {
                if (-not $title) { $title = ([string](Get-ModelProp $e 'name')).Trim() }
                continue
            }
            $cnt++
        }
        $item.count = $cnt
        if (-not $title) { $title = Get-GroupSuffix $n }
        if (-not $title) { $title = $script:UntitledZh }
        $item.title = $title
        $out.Add($item)
    }
    return ,$out.ToArray()
}

function Switch-ModelGroup([string]$product, [string]$file) {
    # Park the current models.json under its own title, then promote the chosen
    # file into its place. The title never lives in the file name alone, which
    # is why it is embedded before the rename can drop it.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $dir = Get-EditionHome $product
    if (-not $file) { throw 'group_required' }
    if ($file -ne [IO.Path]::GetFileName($file)) { throw 'bad_group_name' }
    if (-not (Test-GroupFile $file)) { throw 'bad_group_name' }
    $activePath = Join-Path $dir 'models.json'
    $targetPath = Join-Path $dir $file

    if ($file -eq 'models.json') {
        # Already active. Still guarantee the marker exists so the title shows.
        $t = Get-GroupTitleFromFile $activePath $file
        Set-GroupMarkerInFile $product $activePath $t
        return [pscustomobject]@{ ok = $true; file = 'models.json'; title = $t; parked = '' }
    }
    if (-not (Test-Path -LiteralPath $targetPath)) { throw 'group_not_found' }

    # Parse the target BEFORE any file is moved. Set-GroupMarkerInFile validates
    # only after the swap, so a malformed target used to end up installed as
    # models.json - the client then read an invalid file and dropped every
    # custom model, and the user had to switch back by hand to recover. Checking
    # first turns that into a plain error with nothing changed on disk.
    $preText = ''
    try { $preText = [IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8) }
    catch { throw 'group_not_found' }
    if (-not $preText.Trim()) { throw 'models_empty' }
    if (-not (ConvertFrom-ModelsText $preText).ok) { throw 'models_malformed' }

    $outTitle = Get-GroupTitleFromFile $activePath 'models.json'
    $safeOut = Get-SafeGroupTitle $outTitle $script:UntitledZh
    $inTitle = Get-GroupTitleFromFile $targetPath $file

    $parked = ''
    $parkedPath = ''
    if (Test-Path -LiteralPath $activePath) {
        $dest = Get-UniqueGroupPath $dir $safeOut
        [IO.File]::Move($activePath, $dest)
        $parkedPath = $dest
        $parked = [IO.Path]::GetFileName($dest)
    }
    try {
        [IO.File]::Move($targetPath, $activePath)
    } catch {
        # Two renames make the switch, and the second one can fail on its own
        # (antivirus holding the fresh file, a sharing violation, the file
        # disappearing between the checks above and here). If it does and we
        # leave it there, models.json simply does not exist any more and the
        # client shows no custom models at all - with the user's real list
        # sitting under a parked name they did not choose. Put the parked file
        # back so the previous state survives, then report the failure.
        if ($parkedPath -and (Test-Path -LiteralPath $parkedPath) -and -not (Test-Path -LiteralPath $activePath)) {
            try { [IO.File]::Move($parkedPath, $activePath) } catch { }
        }
        throw
    }
    Set-GroupMarkerInFile $product $activePath $inTitle
    Write-Log ("models group switch: {0} -> [{1}] title={2} parked={3}" -f `
               $product, $file, $inTitle, $parked)
    # Returns a scalar on purpose: this function used to hand back the group
    # array, which a one-element array does not survive (PowerShell unwraps a
    # single-element array returned from a function). The caller re-reads the
    # list with Get-ModelGroups instead, so the shape is always an array.
    return [pscustomobject]@{ ok = $true; file = 'models.json'; title = $inTitle; parked = $parked }
}

function New-ModelGroup([string]$product) {
    # "+" tab: park the current file, start a fresh empty group. No confirmation
    # by design - it is a file rename plus an empty file, and both are reversible
    # by switching back to the parked tab.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $dir = Get-EditionHome $product
    $activePath = Join-Path $dir 'models.json'

    $outTitle = Get-GroupTitleFromFile $activePath 'models.json'
    $safeOut = Get-SafeGroupTitle $outTitle $script:UntitledZh
    $parked = ''
    if (Test-Path -LiteralPath $activePath) {
        $dest = Get-UniqueGroupPath $dir $safeOut
        [IO.File]::Move($activePath, $dest)
        $parked = [IO.Path]::GetFileName($dest)
    }

    $list = New-Object System.Collections.Generic.List[object]
    $list.Add((New-GroupMarkerProps $script:UntitledZh))
    $doc = ConvertTo-ModelsDocument $list 'array' $null
    if (-not (ConvertFrom-ModelsText $doc).ok) { throw 'models_serialize_failed' }
    Write-ModelsText $activePath $doc
    Write-Log ("models group new: {0} parked={1}" -f $product, $parked)
    return [pscustomobject]@{ ok = $true; parked = $parked; title = $script:UntitledZh }
}

function Set-ModelGroupTitle([string]$product, [string]$file, [string]$title) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $dir = Get-EditionHome $product
    if (-not $file) { throw 'group_required' }
    if ($file -ne [IO.Path]::GetFileName($file)) { throw 'bad_group_name' }
    if (-not (Test-GroupFile $file)) { throw 'bad_group_name' }
    $safe = Get-SafeGroupTitle $title $script:UntitledZh

    if ($file -eq 'models.json') {
        Set-GroupMarkerInFile $product (Join-Path $dir 'models.json') $safe
        Write-Log ("models group title: {0} active -> {1}" -f $product, $safe)
        return [pscustomobject]@{ ok = $true; file = 'models.json'; title = $safe }
    }

    $p = Join-Path $dir $file
    if (-not (Test-Path -LiteralPath $p)) { throw 'group_not_found' }
    Set-GroupMarkerInFile $product $p $safe
    # The name follows the title for a parked group, so the tab is legible in
    # the folder too. Skipped when the new name would be the current one.
    #
    # Compare against the plain target name FIRST: Get-UniqueGroupPath answers
    # "first name that does not exist yet", and this file itself is what exists,
    # so asking it directly returned "<name>2" and the file was always renamed
    # (with a stray suffix) even when the title had not effectively changed.
    # Verified: renaming a group to its own current title produced "X2".
    $plain = Join-Path $dir (Get-GroupFileName $safe)
    if ($plain -eq $p) {
        $dest = $p
    } else {
        $dest = Get-UniqueGroupPath $dir $safe
        if ($dest -ne $p) { [IO.File]::Move($p, $dest) }
    }
    Write-Log ("models group title: {0} {1} -> {2} ({3})" -f `
               $product, $file, $safe, [IO.Path]::GetFileName($dest))
    return [pscustomobject]@{ ok = $true; file = [IO.Path]::GetFileName($dest); title = $safe }
}

function Resolve-ModelProbeUrl([string]$url, [bool]$useCustomProtocol) {
    # The client appends /chat/completions unless the model opts out with
    # useCustomProtocol, where the url goes through untouched. The probe has to
    # follow the same rule or it would test a different address than the one
    # real traffic uses.
    $u = ([string]$url).Trim()
    if (-not $u) { return '' }
    if ($useCustomProtocol) { return $u }
    if ($u -match '/chat/completions(?=[/?#]|$)') { return $u }
    return ($u.TrimEnd('/') + '/chat/completions')
}

function Invoke-ModelHttp([string]$method, [string]$url, [string]$apiKey, [string]$body, [int]$timeoutSec) {
    # Minimal HTTP call that also returns the status code on failure. Using
    # HttpClient rather than Invoke-WebRequest because the latter throws on
    # non-2xx and buries the status code in the exception.
    $out = [pscustomobject]@{ ok = $false; status = 0; body = ''; error = ''; elapsedMs = 0 }
    if (-not $url) { $out.error = 'url_required'; return $out }
    try { $req = [Net.WebRequest]::Create($url) }
    catch { $out.error = 'url_invalid'; return $out }
    if ($null -eq $req) { $out.error = 'url_invalid'; return $out }

    # Old PowerShell on Windows may still default to TLS 1.0, which every modern
    # endpoint rejects. Ask for 1.2 explicitly.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req.Method = $method
        $req.Timeout = $timeoutSec * 1000
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'WorkBuddyKeeper/' + $AppVersion
        if ($apiKey) { $req.Headers['Authorization'] = 'Bearer ' + $apiKey }
        if ($body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            $rs.Write($bytes, 0, $bytes.Length)
            $rs.Close()
        }
        $resp = $req.GetResponse()
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $out.body = $sr.ReadToEnd()
            $sr.Close()
        } finally { $resp.Close() }
        $out.status = [int]$resp.StatusCode
        $out.ok = ($out.status -ge 200 -and $out.status -lt 300)
    } catch [Net.WebException] {
        $we = $_.Exception
        if ($null -ne $we.Response) {
            # A real HTTP answer (401, 404, ...) - keep the code and the body,
            # they are what tells the user what actually went wrong.
            try {
                $sr = New-Object IO.StreamReader($we.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $out.body = $sr.ReadToEnd()
                $sr.Close()
            } catch { }
            try { $out.status = [int]$we.Response.StatusCode } catch { $out.status = 0 }
        } else {
            $out.error = $we.Status.ToString()   # NameResolutionFailure, Timeout, ...
            $out.status = 0
        }
    } catch {
        $out.error = 'request_failed'
    } finally {
        $sw.Stop()
        $out.elapsedMs = [int]$sw.ElapsedMilliseconds
        try { $req.Close() } catch { }
    }
    return $out
}

function Get-ModelProbeUrlCandidates([string]$url) {
    # THE candidate list for a model listing. Every caller shares it - the batch
    # importer and the editor's "pick a model" - so the two can no longer drift
    # apart and disagree about which address a given input should reach.
    #
    # The order is fixed and deliberately dumb:
    #
    #   1. the url exactly as pasted   (already a listing address)
    #   2. <origin>/models
    #   3. <origin>/v1/models
    #   4. <pasted>/models
    #
    # The user pastes all sorts of things - a bare origin, an origin plus /v1, a
    # full chat address - and there is no way to tell which shape a given gateway
    # will answer on, so all four are tried in a predictable order. Every
    # candidate that was tried is reported back, so the outcome is explainable
    # rather than silently landing on whichever one happened to answer.
    #
    # useCustomProtocol is NOT consulted here: it only governs whether the client
    # appends /chat/completions to the chat address, and the batch importer has
    # no such switch at all.
    # Returns a plain array (no comma-prefix). Callers wrap with @() - that is
    # the one combination that survives BOTH shapes: an empty result, a single
    # result and many. The comma trick used elsewhere in this file preserves
    # array-ness on a direct assignment but turns into a nested one-element
    # array the moment someone writes @(f), which is a trap worth avoiding.
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $url) { return $out.ToArray() }
    $u = ([string]$url).Trim()
    if (-not $u) { return $out.ToArray() }

    $seen = @{}
    $add = {
        param($c)
        if (-not $c) { return }
        $c = ([string]$c).TrimEnd('/')
        if ($c -and -not $seen.ContainsKey($c)) { $seen[$c] = $true; $out.Add($c) }
    }

    & $add $u

    $m = [regex]::Match($u.TrimEnd('/'), '^(https?://[^/]+)(/.*)?$')
    if ($m.Success) {
        $origin = $m.Groups[1].Value
        & $add ($origin + '/models')
        & $add ($origin + '/v1/models')
    }
    & $add ($u.TrimEnd('/') + '/models')
    return $out.ToArray()
}

function Get-ModelListWithFallback([string]$url, [string]$apiKey, [bool]$useCustomProtocol) {
    # The batch importer only gets an origin or a /v1 root from the user, so it
    # walks the candidate listing addresses until one answers with a usable
    # data array. Which candidate won, and which were tried, are both reported -
    # "it worked on the third guess" is information the user needs, not noise.
    $out = [pscustomobject]@{
        ok         = $false
        status     = 0
        code       = ''
        message    = ''
        usedUrl    = ''
        tried      = @()
        models     = @()
        raw        = ''
    }
    if (-not $url) { $out.code = 'url_required'; $out.message = 'url is empty'; return $out }
    if (-not $apiKey) { $out.code = 'key_required'; $out.message = 'apiKey is empty'; return $out }

    $cands = @(Get-ModelProbeUrlCandidates $url)
    if ($cands.Count -eq 0) {
        $out.code = 'list_failed'
        $out.message = 'could not derive a model listing address from the url'
        return $out
    }

    $tried = New-Object System.Collections.Generic.List[object]
    $reasons = New-Object System.Collections.Generic.List[string]
    $lastStatus = 0
    $lastMessage = ''
    foreach ($c in $cands) {
        $r = Invoke-ModelHttp 'GET' $c $apiKey '' 20
        $tried.Add([pscustomobject]@{ url = $c; status = $r.status; ok = [bool]$r.ok })
        $lastStatus = $r.status
        if (-not $r.ok) {
            if ($r.status -eq 401 -or $r.status -eq 403) { $lastMessage = 'HTTP ' + $r.status + ' - the key was rejected' }
            elseif ($r.status -gt 0) { $lastMessage = 'HTTP ' + $r.status }
            else { $lastMessage = [string]$r.error }
            $reasons.Add($c + ' -> ' + $lastMessage)
            # A rejected key will be rejected everywhere; stop guessing.
            if ($r.status -eq 401 -or $r.status -eq 403) { break }
            continue
        }
        $parsed = $null
        try { $parsed = $r.body | ConvertFrom-Json } catch { }
        if ($null -eq $parsed) {
            $lastMessage = 'HTTP ' + $r.status + ' but the body is not valid JSON'
            $reasons.Add($c + ' -> ' + $lastMessage)
            continue
        }
        $p = $parsed.PSObject.Properties['data']
        if ($null -eq $p) {
            $lastMessage = 'HTTP ' + $r.status + ' but the body has no data array'
            $reasons.Add($c + ' -> ' + $lastMessage)
            continue
        }
        $items = To-ItemArray $p.Value
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($it in $items) {
            if ($null -eq $it) { continue }
            $mid = [string](Get-ModelProp $it 'id')
            if (-not $mid) { $mid = [string](Get-ModelProp $it 'modelId') }
            if (-not $mid) { continue }
            $list.Add((New-ListingItem $it $mid))
            if ($list.Count -ge 500) { break }
        }
        if ($list.Count -eq 0) { $lastMessage = 'the listing came back empty'; continue }
        $out.ok = $true
        $out.status = $r.status
        $out.code = 'ok'
        $out.message = 'model list fetched'
        $out.usedUrl = $c
        $out.models = $list.ToArray()
        $out.tried = $tried.ToArray()
        return $out
    }

    $out.status = $lastStatus
    $out.code = 'list_failed'
    $out.message = $lastMessage
    $out.tried = $tried.ToArray()
    return $out
}

function Test-ModelUsable([string]$product, $patch, [string]$originalId, [bool]$listOnly) {
    # Two steps, mirroring what the client itself does:
    #   1. GET the model listing and require HTTP 200 with a parseable data array
    #   2. POST a one-token chat request to prove the model can actually answer
    # Nothing is written to disk unless step 2 passes.
    # $listOnly stops after step 1 and returns the entries, which is what the
    # "pick a model" dialog needs.
    $url = ([string]$patch.url).Trim()
    $apiKey = [string]$patch.apiKey
    $id = ([string]$patch.id).Trim()
    $useCustom = $false
    if ($null -ne $patch.PSObject.Properties['useCustomProtocol']) { $useCustom = [bool]$patch.useCustomProtocol }

    # For an existing entry the stored key is the real one: the form leaves the
    # box empty when the key is unchanged (encrypted keys are never shown).
    if (-not $apiKey -and $originalId) {
        # Prefer the same entry an edit would land on (visible twin first), so a
        # duplicate pair does not test against the hidden copy's key.
        $apiKey = Get-ModelStoredApiKey $product $originalId
    }

    $result = [pscustomobject]@{
        ok          = $false
        stage       = 'validate'
        code        = ''
        message     = ''
        status      = 0
        elapsedMs   = 0
        listUrl     = ''
        chatUrl     = ''
        modelCount  = -1
        models      = @()
        reply       = ''
    }

    # --- required fields -----------------------------------------------------
    if (-not $url)     { $result.code = 'url_required';  $result.message = 'url is empty'; return $result }
    if (-not $apiKey)  { $result.code = 'key_required';  $result.message = 'apiKey is empty'; return $result }
    # The listing does not need a model id; the chat probe does.
    if (-not $listOnly -and -not $id) { $result.code = 'id_required'; $result.message = 'id is empty'; return $result }

    # --- step 1: listing ----------------------------------------------------
    # Same candidate list as the batch importer, same order. This dialog used to
    # have its own single-candidate rule, which meant the two could disagree
    # about where a listing lives; now there is one list and one order.
    $result.stage = 'list'
    $cands = @(Get-ModelProbeUrlCandidates $url)
    if ($cands.Count -eq 0) {
        $result.code = 'list_failed'
        $result.message = 'could not derive a model listing address from the url'
        return $result
    }
    $result.listUrl = [string]$cands[0]

    $r = $null
    $lu = ''
    $listTried = New-Object System.Collections.Generic.List[object]
    $listReason = ''
    $parsed = $null
    foreach ($c in $cands) {
        $r = Invoke-ModelHttp 'GET' $c $apiKey '' 30
        $listTried.Add([pscustomobject]@{ url = $c; status = $r.status; ok = [bool]$r.ok })
        $result.status = $r.status
        $result.elapsedMs = $r.elapsedMs
        if (-not $r.ok) {
            if ($r.status -eq 401 -or $r.status -eq 403) {
                $listReason = 'HTTP ' + $r.status + ' - the key was rejected'
                break
            }
            if ($r.status -eq 404) { $listReason = 'HTTP 404 - no model listing at this address' }
            elseif ($r.status -gt 0) { $listReason = 'HTTP ' + $r.status }
            else { $listReason = [string]$r.error }
            continue
        }
        $parsed = $null
        try { $parsed = $r.body | ConvertFrom-Json } catch { }
        if ($null -eq $parsed) {
            # Keep the shape diagnosis instead of letting the next candidate's
            # HTTP code overwrite it: "answered 200 but not JSON" is the useful
            # fact, and losing it was a real debugging dead end.
            $listReason = 'HTTP ' + $r.status + ' but the body is not valid JSON'
            continue
        }
        if ($null -eq $parsed.PSObject.Properties['data']) {
            $listReason = 'HTTP ' + $r.status + ' but the body has no data array'
            $parsed = $null
            continue
        }
        $lu = $c
        break
    }
    $result.listUrl = $lu
    if ($null -eq $parsed) {
        $result.code = 'list_failed'
        $result.message = $listReason
        if ($r -and $r.body) {
            $s = ([string]$r.body).Trim()
            if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + '...' }
            $result.reply = $s
        }
        return $result
    }
    $p = $parsed.PSObject.Properties['data']
    if ($null -eq $p) {
        $result.code = 'list_failed'
        $result.message = 'HTTP ' + $r.status + ' but the body has no data array'
        return $result
    }
    # To-ItemArray already returns a real array; wrapping it in @() again would
    # nest the whole list into a single element.
    $items = To-ItemArray $p.Value
    $result.status = $r.status
    $result.modelCount = $items.Count
    # Same normalisation the batch importer uses, so a model looks the same
    # wherever it is picked from. Kept small: the picker only shows id + name.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        if ($null -eq $it) { continue }
        $mid = [string](Get-ModelProp $it 'id')
        if (-not $mid) { $mid = [string](Get-ModelProp $it 'modelId') }
        if (-not $mid) { continue }
        $out.Add((New-ListingItem $it $mid))
        if ($out.Count -ge 300) { break }
    }
    $result.models = $out.ToArray()

    # --- step 2: minimal chat ----------------------------------------------
    if ($listOnly) {
        # The listing is all this caller wanted; the id may be empty or wrong.
        $result.ok = $true
        $result.stage = 'list'
        $result.code = 'ok'
        $result.message = 'model list fetched'
        return $result
    }
    $result.stage = 'chat'
    $chatUrl = Resolve-ModelProbeUrl $url $useCustom
    $result.chatUrl = $chatUrl
    $payload = @{
        model      = $id
        messages   = @(@{ role = 'user'; content = 'Reply with OK.' })
        max_tokens = 1
        stream     = $false
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $r2 = Invoke-ModelHttp 'POST' $chatUrl $apiKey $json 60
    $result.status = $r2.status
    $result.elapsedMs = $r2.elapsedMs
    if (-not $r2.ok) {
        $result.code = 'chat_failed'
        if ($r2.status -eq 404) { $result.message = 'HTTP 404 - the model id probably does not exist at this address' }
        elseif ($r2.status -eq 401 -or $r2.status -eq 403) { $result.message = 'HTTP ' + $r2.status + ' - the key was rejected' }
        elseif ($r2.status -eq 429) { $result.message = 'HTTP 429 - rate limited, try again later' }
        elseif ($r2.status -gt 0) { $result.message = 'HTTP ' + $r2.status }
        else { $result.message = $r2.error }
        # Surface the server's own words - they are the most useful thing here.
        if ($r2.body) {
            $snippet = ([string]$r2.body).Trim()
            if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
            $result.reply = $snippet
        }
        return $result
    }

    $parsed2 = $null
    try { $parsed2 = $r2.body | ConvertFrom-Json } catch { }
    if ($null -eq $parsed2) {
        $result.code = 'chat_bad_response'
        $result.message = 'the reply is not valid JSON'
        return $result
    }
    # Same permissive rule as the "test chat" button: a 2xx that parses is a
    # reachable endpoint, empty content included; only an explicit error
    # envelope fails. See Test-ModelChatReply for why.
    $chk = Test-ModelChatReply $parsed2
    if (-not $chk.ok) {
        $result.code = 'chat_bad_response'
        $result.message = 'HTTP ' + $r2.status + ' but the endpoint reported an error'
        if ($chk.error) { $result.message = $result.message + ': ' + $chk.error }
        return $result
    }
    $result.reply = $chk.text
    $result.ok = $true
    $result.code = 'ok'
    $result.message = 'model answered'
    return $result
}

function Test-ModelChatReply($parsed) {
    # Decides whether a chat response body proves the model answered.
    #
    # Deliberately PERMISSIVE, and that is the important part. An earlier version
    # required non-empty message.content, which made working reasoning models
    # report "unavailable": the probe sends max_tokens=1, a thinking model spends
    # that single token on reasoning_content, and content legitimately comes back
    # as "". The client version before that (1.6.2) simply treated every HTTP 200
    # as success, and the buttons worked.
    #
    # So the rule is: a 2xx that parses as JSON is a reachable chat endpoint,
    # UNLESS the body is an explicit error envelope ({"error": ...}), which some
    # gateways return with a 200. That rejects the one case that matters for
    # correctness - a 200 carrying "bad request" - while never calling a working
    # model broken. Reply text is carried along when present, for display only.
    $out = [pscustomobject]@{ ok = $false; text = ''; error = '' }
    if ($null -eq $parsed) { return $out }

    # Explicit error envelope: the endpoint answered, but it said "no".
    $ep = $parsed.PSObject.Properties['error']
    if ($null -ne $ep -and $null -ne $ep.Value) {
        if ($ep.Value -is [string]) { $out.error = [string]$ep.Value }
        else {
            $m = $ep.Value.PSObject.Properties['message']
            if ($null -ne $m) { $out.error = [string]$m.Value }
            if (-not $out.error) { $out.error = 'the endpoint returned an error' }
        }
        return $out
    }

    # A well-formed completion: take the text if there is any. Its ABSENCE is
    # fine (see above); the shape being present is not required to pass either.
    $ch = $parsed.PSObject.Properties['choices']
    if ($null -ne $ch) {
        $first = (To-ItemArray $ch.Value)[0]
        if ($null -ne $first) {
            $msg = $first.PSObject.Properties['message']
            if ($null -ne $msg -and $null -ne $msg.Value) {
                $c = $msg.Value.PSObject.Properties['content']
                if ($null -ne $c -and $null -ne $c.Value) { $out.text = [string]$c.Value }
            } else {
                $dl = $first.PSObject.Properties['delta']
                if ($null -ne $dl -and $null -ne $dl.Value) {
                    $c = $dl.Value.PSObject.Properties['content']
                    if ($null -ne $c -and $null -ne $c.Value) { $out.text = [string]$c.Value }
                }
            }
        }
    }
    $out.ok = $true
    return $out
}

function Get-ModelChatUrlCandidates([string]$url, [bool]$useCustomProtocol) {
    # Candidate chat addresses for the editor's "test chat" button, tried in
    # order. The user typically pastes a base like "https://host/v1" and expects
    # the tool to work out that the conversation endpoint is one segment deeper.
    #
    # This is deliberately more forgiving than Resolve-ModelProbeUrl (which is
    # used when saving/picking and must not paper over a wrong address): here the
    # whole point is to discover the right address and hand it back so the form
    # can be corrected in place.
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $url) { return ,$out.ToArray() }
    $u = ([string]$url).Trim()
    if ($useCustomProtocol) {
        # "use as-is" means exactly that: no guessing.
        $out.Add($u)
        return ,$out.ToArray()
    }
    $seen = @{}
    $add = {
        param($c)
        if (-not $c) { return }
        $c = $c.TrimEnd('/')
        if ($c -and -not $seen.ContainsKey($c)) { $seen[$c] = $true; $out.Add($c) }
    }

    $m = [regex]::Match($u.TrimEnd('/'), '^(https?://[^/]+)(/.*)?$')
    if (-not $m.Success) { & $add $u; return ,$out.ToArray() }
    $origin = $m.Groups[1].Value
    $path = $m.Groups[2].Value

    # Already a full chat path: that is the only thing worth trying first, but
    # a trailing /v1 duplicate is still added in case the host wants it.
    if ($u -match '/chat/completions(?=[/?#]|$)') {
        & $add $u
        return ,$out.ToArray()
    }

    # 1. the url as pasted + /chat/completions  (host/v1 -> host/v1/chat/completions)
    #    TrimEnd first: a url the user ended with "/" would otherwise produce
    #    "host/v1//chat/completions" - a double slash the endpoint may 404 on.
    & $add ($u.TrimEnd('/') + '/chat/completions')
    # 2. the bare origin + /v1/chat/completions  (host -> host/v1/chat/completions)
    & $add ($origin.TrimEnd('/') + '/v1/chat/completions')
    # 3. last resort: the pasted path untouched (a host that serves chat at /)
    & $add $u
    return ,$out.ToArray()
}

function Test-ModelChat([string]$product, $patch, [string]$originalId, [int]$hint = -1) {
    # The editor's "test chat" button. Unlike Test-ModelUsable this does NOT
    # walk the model listing first: the user's rule is "test the return code,
    # then test the conversation". So it posts one minimal chat request per
    # candidate address and accepts a candidate only when BOTH hold:
    #   - the HTTP status is a success code, and
    #   - the body really is a chat completion (choices[0].message.content).
    #
    # When the address that works is not the one typed in, it is reported back
    # as fixedUrl so the form can replace the field with the working value.
    #
    # $hint is the entry's position in the file array. Two entries can share one
    # id (a visible one and a hidden twin); the listing's "test" button passes the
    # position so the key looked up is the one on the card that was clicked,
    # matching what edit / delete / hide already do.
    $url = ([string]$patch.url).Trim()
    $apiKey = [string]$patch.apiKey
    $id = ([string]$patch.id).Trim()
    $useCustom = $false
    if ($null -ne $patch.PSObject.Properties['useCustomProtocol']) { $useCustom = [bool]$patch.useCustomProtocol }

    # An existing entry's stored key is the real one; the editor leaves the box
    # empty when the key is unchanged (encrypted keys are never shown).
    #
    # Get-ModelStoredApiKey returns '' for an ENCRYPTED key, which lands in the
    # same place as "there is no key". Those are different situations for the
    # user: an encrypted key just needs to be typed in the editor once, whereas
    # a missing key has to be filled in. Say which one it is.
    $keyIsEncrypted = $false
    if (-not $apiKey -and $originalId) {
        # Prefer the same entry an edit would land on (visible twin first), so a
        # duplicate pair does not test against the hidden copy's key.
        $apiKey = Get-ModelStoredApiKey $product $originalId $hint
        if (-not $apiKey) {
            $rawStored = Get-ModelsRaw $product
            if ($rawStored.valid) {
                $si = Find-ModelEntryIndex $rawStored.items $originalId $hint
                if ($si -ge 0) {
                    $sk = Get-ModelProp $rawStored.items[$si] 'apiKey'
                    if ($null -ne $sk -and (Test-WbEncrypted $sk)) { $keyIsEncrypted = $true }
                }
            }
        }
    }

    $result = [pscustomobject]@{
        ok         = $false
        code       = ''
        message    = ''
        status     = 0
        elapsedMs  = 0
        chatUrl    = ''
        fixedUrl   = ''
        reply      = ''
        tried      = @()
    }
    if (-not $url)    { $result.code = 'url_required'; $result.message = 'url is empty'; return $result }
    if (-not $apiKey) {
        if ($keyIsEncrypted) {
            $result.code = 'key_encrypted'
            $result.message = 'the stored key is encrypted; type it in the editor once to test'
        } else {
            $result.code = 'key_required'
            $result.message = 'apiKey is empty'
        }
        return $result
    }
    if (-not $id)     { $result.code = 'id_required'; $result.message = 'id is empty'; return $result }

    $cands = Get-ModelChatUrlCandidates $url $useCustom
    if ($cands.Count -eq 0) {
        $result.code = 'url_invalid'
        $result.message = 'the address could not be parsed'
        return $result
    }

    $payload = @{
        model      = $id
        messages   = @(@{ role = 'user'; content = 'Reply with OK.' })
        max_tokens = 1
        stream     = $false
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress

    $tried = New-Object System.Collections.Generic.List[object]
    $lastStatus = 0
    $lastMessage = ''
    $lastBody = ''
    $spentMs = 0

    foreach ($c in $cands) {
        # Step 1 + 2 in one request: the status code and the conversation come
        # from the same POST, so a success code with a broken body is still a
        # failure here rather than being reported as "model works".
        $r = Invoke-ModelHttp 'POST' $c $apiKey $json 45
        $spentMs += [int]$r.elapsedMs
        $tried.Add([pscustomobject]@{ url = $c; status = $r.status; ok = [bool]$r.ok })
        $lastStatus = $r.status
        if ($r.body) {
            $b = ([string]$r.body).Trim()
            if ($b.Length -gt 300) { $b = $b.Substring(0, 300) + '...' }
            $lastBody = $b
        }

        if (-not $r.ok) {
            if ($r.status -eq 401 -or $r.status -eq 403) {
                $lastMessage = 'HTTP ' + $r.status + ' - the key was rejected'
                # A rejected key is rejected everywhere; stop guessing.
                break
            }
            if ($r.status -eq 429) { $lastMessage = 'HTTP 429 - rate limited' }
            elseif ($r.status -gt 0) { $lastMessage = 'HTTP ' + $r.status }
            else { $lastMessage = [string]$r.error }
            continue
        }

        $parsed = $null
        try { $parsed = $r.body | ConvertFrom-Json } catch { }
        if ($null -eq $parsed) {
            $lastMessage = 'HTTP ' + $r.status + ' but the body is not valid JSON'
            continue
        }
        # A reachable endpoint. Do NOT require non-empty content: with
        # max_tokens=1 a reasoning model legitimately answers with an empty
        # string (its one token went into reasoning_content). Only an explicit
        # error envelope is a failure. See Test-ModelChatReply.
        $chk = Test-ModelChatReply $parsed
        if (-not $chk.ok) {
            $lastMessage = 'HTTP ' + $r.status + ' but the endpoint reported an error'
            if ($chk.error) { $lastMessage = $lastMessage + ': ' + $chk.error }
            continue
        }
        $text = $chk.text

        $result.ok = $true
        $result.code = 'ok'
        $result.message = 'model answered'
        $result.status = $r.status
        $result.reply = $text
        $result.chatUrl = $c
        $result.elapsedMs = $spentMs
        # Only report a replacement when the working address differs from what
        # the user typed: the form keeps its own value otherwise.
        if ($c -ne $url.TrimEnd('/') -and $c -ne $url) { $result.fixedUrl = $c }
        $result.tried = $tried.ToArray()
        return $result
    }

    $result.code = 'chat_failed'
    $result.status = $lastStatus
    $result.message = $lastMessage
    $result.reply = $lastBody
    $result.elapsedMs = $spentMs
    if ($cands.Count -gt 0) { $result.chatUrl = $cands[0] }
    $result.tried = $tried.ToArray()
    return $result
}

function Test-ModelBatch([string]$url, [string]$apiKey, $ids, [bool]$useCustomProtocol, [int]$concurrency) {
    # Probes many model ids against one endpoint. Each id gets the same two-step
    # probe as the single-model path (chat request, real answer), but they run in
    # parallel: a listing with 30 models would take minutes one at a time.
    #
    # Concurrency is a runspace pool - Start-ThreadJob's jobs are separate
    # processes on Windows PowerShell 5.1 and would not see the helper functions.
    # Every property the function may set is declared up front: PowerShell raises
    # "property cannot be found" on assigning to one that does not exist, and the
    # error paths below set these.
    $out = [pscustomobject]@{ ok = $true; error = ''; results = @(); chatUrl = ''; triedChat = @() }
    if (-not $url)     { $out.ok = $false; $out.error = 'url_required'; return $out }
    if (-not $apiKey)  { $out.ok = $false; $out.error = 'key_required'; return $out }

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($x in (To-ItemArray $ids)) {
        $s = ([string]$x).Trim()
        if ($s) { $list.Add($s) }
    }
    if ($list.Count -eq 0) { $out.ok = $false; $out.error = 'ids_required'; return $out }
    if ($list.Count -gt 200) { $list = $list.GetRange(0, 200) }

    if ($concurrency -lt 1) { $concurrency = 8 }
    if ($concurrency -gt 16) { $concurrency = 16 }

    # The chat address falls back the same way the listing does: try the derived
    # /chat/completions first, and if every model 404s there, try /v1/chat/completions.
    #
    # Several candidates collapse onto the same chat address - "https://x" alone
    # yields /chat/completions twice, and a pasted full chat address yields it up
    # to three times. Left in, a dead chunk would probe the very same address
    # again (wasting a whole round of timeouts), and the LAST candidate won, so
    # the error shown came from a different address than the one that failed
    # first. Deduplicate, and keep the first candidate's results when nothing
    # answered anywhere.
    $cands = New-Object System.Collections.Generic.List[string]
    $seenCands = @{}
    foreach ($c in @(Get-ModelProbeUrlCandidates $url)) {
        $cText = ([string]$c).TrimEnd('/')
        # strip trailing /models so "https://x/v1/models" becomes "https://x/v1"
        # instead of the nonsensical "https://x/v1/models/chat/completions".
        # Repeat it: the candidate list appends /models to the pasted text too,
        # so an input that already ends in /models arrives as "x/models/models"
        # and would otherwise leave one /models behind.
        while ($cText -match '/models$') { $cText = $cText.Substring(0, $cText.Length - 7).TrimEnd('/') }
        if (-not $cText) { continue }
        if ($cText -notmatch '/chat/completions$') { $cText = $cText + '/chat/completions' }
        if (-not $seenCands.ContainsKey($cText)) { $seenCands[$cText] = $true; $cands.Add($cText) }
    }
    if ($cands.Count -eq 0) { $out.ok = $false; $out.error = 'url_invalid'; return $out }

    $script:batchProbe = {
        param($chatUrl, $apiKey, $modelId, $userAgent)
        $res = [pscustomobject]@{
            id = $modelId; ok = $false; status = 0; elapsedMs = 0
            code = ''; message = ''; reply = ''
        }
        $req = $null
        try { $req = [Net.WebRequest]::Create($chatUrl) } catch { }
        if ($null -eq $req) { $res.code = 'url_invalid'; $res.message = 'the address could not be parsed'; return $res }
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
        $payload = @{
            model      = $modelId
            messages   = @(@{ role = 'user'; content = 'Reply with OK.' })
            max_tokens = 1
            stream     = $false
        }
        $json = $payload | ConvertTo-Json -Depth 6 -Compress
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $req.Method = 'POST'
            $req.Timeout = 45000
            $req.AllowAutoRedirect = $true
            $req.UserAgent = $userAgent
            $req.Headers['Authorization'] = 'Bearer ' + $apiKey
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            $rs.Write($bytes, 0, $bytes.Length)
            $rs.Close()
            $resp = $req.GetResponse()
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Close()
            } finally { $resp.Close() }
            $res.status = [int]$resp.StatusCode
            $res.elapsedMs = [int]$sw.ElapsedMilliseconds
            $parsed = $null
            try { $parsed = $body | ConvertFrom-Json } catch { }
            if ($null -eq $parsed) {
                $res.code = 'chat_bad_response'
                $res.message = 'the reply is not valid JSON'
                $s = ([string]$body).Trim(); if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                $res.reply = $s
                return $res
            }
            # Same permissive rule as the single-model probe: a 2xx that parses
            # as JSON is a reachable endpoint, and an EMPTY content is still a
            # pass (max_tokens=1 on a reasoning model puts its one token into
            # reasoning_content, so content legitimately comes back ""). The one
            # thing that does fail is an explicit error envelope returned with a
            # 200, which is what a body check is actually for.
            #
            # Inlined on purpose: this runs inside a runspace pool that only sees
            # the script block, not the module's helpers.
            $errMsg = ''
            $ep = $parsed.PSObject.Properties['error']
            if ($null -ne $ep -and $null -ne $ep.Value) {
                if ($ep.Value -is [string]) { $errMsg = [string]$ep.Value }
                else {
                    $m = $ep.Value.PSObject.Properties['message']
                    if ($null -ne $m) { $errMsg = [string]$m.Value }
                    if (-not $errMsg) { $errMsg = 'the endpoint returned an error' }
                }
            }
            if ($errMsg) {
                $res.code = 'chat_bad_response'
                $res.message = 'HTTP ' + $res.status + ' but the endpoint reported an error: ' + $errMsg
                $s = ([string]$body).Trim(); if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                $res.reply = $s
                return $res
            }
            # Pick up any reply text for display; its absence is not a failure.
            $ch = $parsed.PSObject.Properties['choices']
            if ($null -ne $ch) {
                $first = @($ch.Value)[0]
                if ($null -ne $first) {
                    $msg = $first.PSObject.Properties['message']
                    if ($null -ne $msg -and $null -ne $msg.Value) {
                        $c = $msg.Value.PSObject.Properties['content']
                        if ($null -ne $c -and $null -ne $c.Value) { $res.reply = [string]$c.Value }
                    } else {
                        $dl = $first.PSObject.Properties['delta']
                        if ($null -ne $dl -and $null -ne $dl.Value) {
                            $c = $dl.Value.PSObject.Properties['content']
                            if ($null -ne $c -and $null -ne $c.Value) { $res.reply = [string]$c.Value }
                        }
                    }
                }
            }
            $res.ok = $true
            $res.code = 'ok'
            $res.message = 'model answered'
            return $res
        } catch [Net.WebException] {
            $res.elapsedMs = [int]$sw.ElapsedMilliseconds
            $we = $_.Exception
            if ($null -ne $we.Response) {
                try {
                    $res.status = [int]$we.Response.StatusCode
                    $sr = New-Object IO.StreamReader($we.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                    $s = $sr.ReadToEnd(); $sr.Close()
                    if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                    $res.reply = $s
                } catch { }
            }
            $res.code = 'chat_failed'
            if ($res.status -eq 404) { $res.message = 'HTTP 404 - the model id probably does not exist here' }
            elseif ($res.status -eq 401 -or $res.status -eq 403) { $res.message = 'HTTP ' + $res.status + ' - the key was rejected' }
            elseif ($res.status -eq 429) { $res.message = 'HTTP 429 - rate limited' }
            elseif ($res.status -gt 0) { $res.message = 'HTTP ' + $res.status }
            else { $res.message = [string]$we.Message }
            return $res
        } catch {
            $res.elapsedMs = [int]$sw.ElapsedMilliseconds
            $res.code = 'chat_failed'
            $res.message = [string]$_.Exception.Message
            return $res
        }
    }

    $pool = $null
    $results = New-Object System.Collections.Generic.List[object]
    $usedChat = ''
    $firstResults = $null
    foreach ($chatUrl in $cands) {
        $pool = [runspacefactory]::CreateRunspacePool(1, $concurrency)
        $pool.Open()
        $handles = New-Object System.Collections.Generic.List[object]
        foreach ($mid in $list) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:batchProbe).AddArgument($chatUrl).AddArgument($apiKey).AddArgument($mid).AddArgument('WorkBuddyKeeper/' + $AppVersion)
            $handles.Add([pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke() })
        }
        $results = New-Object System.Collections.Generic.List[object]
        foreach ($x in $handles) {
            try {
                $r = $x.ps.EndInvoke($x.h)
                foreach ($one in (To-ItemArray $r)) { if ($null -ne $one) { $results.Add($one) } }
            } catch {
                $results.Add([pscustomobject]@{ id = '?'; ok = $false; status = 0; elapsedMs = 0
                                               code = 'probe_error'; message = [string]$_.Exception.Message; reply = '' })
            } finally { $x.ps.Dispose() }
        }
        $pool.Close(); $pool.Dispose(); $pool = $null
        $usedChat = $chatUrl
        # Nothing answered anywhere means we fall through to the next candidate.
        # Remember the FIRST candidate's results: if no candidate ever answers,
        # those are the ones worth showing - the first address is the one derived
        # straight from what the user typed. Reporting the last candidate instead
        # showed the error from an address the user never chose.
        if ($null -eq $firstResults) { $firstResults = $results }
        # If anything answered, this address is the right one. Only when every
        # single model failed do we try the next candidate address.
        $anyOk = $false
        foreach ($r in $results) { if ($r.ok) { $anyOk = $true; break } }
        if ($anyOk) { break }
    }
    if ($null -ne $pool) { try { $pool.Close(); $pool.Dispose() } catch { } }
    if ($null -ne $firstResults) {
        $anyOk = $false
        foreach ($r in $results) { if ($r.ok) { $anyOk = $true; break } }
        if (-not $anyOk) {
            $results = $firstResults
            $usedChat = [string]@($cands)[0]
        }
    }

    $out.chatUrl = $usedChat
    $out.triedChat = $cands.ToArray()
    $out.results = $results.ToArray()
    return $out
}

function Get-ModelGroupEntries([string]$product, [string]$file, $ids) {
    # One resolved "what to test" row per model, from whichever file was asked
    # for. Split out from the probe so the active file and a parked group go
    # through exactly the same resolution rules - including the two cases that
    # are reported as failures rather than skipped (no url, encrypted key).
    #
    # Returns @{ ok; error; entries }.
    $out = [pscustomobject]@{ ok = $true; error = ''; entries = @() }
    if (-not (Test-Edition $product)) { $out.ok = $false; $out.error = 'unknown_edition'; return $out }
    if (-not $file) { $file = 'models.json' }
    $dir = Get-EditionHome $product
    $path = Join-Path $dir $file
    if (-not (Test-Path -LiteralPath $path)) { $out.ok = $false; $out.error = 'group_not_found'; return $out }

    $items = $null
    if ($file -eq 'models.json') {
        $raw = Get-ModelsRaw $product
        if (-not $raw.valid) { $out.ok = $false; $out.error = 'models_malformed'; return $out }
        $items = $raw.items
    } else {
        $text = ''
        try { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
        catch { $out.ok = $false; $out.error = 'read_failed'; return $out }
        $parsed = ConvertFrom-ModelsText $text
        if (-not $parsed.ok) { $out.ok = $false; $out.error = 'models_malformed'; return $out }
        $items = $parsed.items
    }

    $want = @{}
    foreach ($x in (To-ItemArray $ids)) { $s = ([string]$x).Trim(); if ($s) { $want[$s] = $true } }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in $items) {
        if ($null -eq $e) { continue }
        if (-not ($e -is [psobject]) -or $e -is [string] -or $e -is [ValueType]) { continue }
        if (Test-GroupMarker $e) { continue }        # the title marker is not a model
        if (Test-ModelArchived $e) { continue }      # hidden entries are not in the client either
        $mid = ([string](Get-ModelKey $e)).Trim()
        if (-not $mid) { continue }
        if ($want.Count -gt 0 -and -not $want.ContainsKey($mid)) { continue }
        $url = ([string](Get-ModelProp $e 'url')).Trim()
        # An encrypted key cannot be used here: this process has no way to
        # decrypt what the client encrypted. Reported as a failure with a hint,
        # not silently skipped.
        #
        # Test-WbEncrypted looks for an "envelope" property, so it must see the
        # RAW value - casting to [string] first produced "@{envelope=...}" and
        # the check then always said "not encrypted", which sent that text out
        # as the Bearer token.
        $rawKey = Get-ModelProp $e 'apiKey'
        $key = ''
        $enc = $false
        if ($null -ne $rawKey) {
            if (Test-WbEncrypted $rawKey) { $enc = $true }
            else { $key = [string]$rawKey }
        }
        $ucp = $false
        $p = Get-ModelProp $e 'useCustomProtocol'
        if ($null -ne $p) { $ucp = [bool]$p }
        $list.Add([pscustomobject]@{ id = $mid; url = $url; apiKey = $key; enc = $enc; ucp = $ucp })
        if ($list.Count -ge 200) { break }
    }
    $out.entries = $list.ToArray()
    return $out
}

function Test-ModelGroupChatEntries($list, [int]$concurrency) {
    # The probe runner. Takes the rows Get-ModelGroupEntries produced and hits
    # each model's OWN chat address with its OWN key, in parallel.
    # Entries that cannot be probed at all become failure rows here, so the
    # caller always gets one result per model it asked about.
    $out = New-Object System.Collections.Generic.List[object]
    if ($concurrency -lt 1) { $concurrency = 8 }
    if ($concurrency -gt 16) { $concurrency = 16 }
    $rows = @($list)
    if ($rows.Count -eq 0) { return ,$out.ToArray() }

    $pool = [runspacefactory]::CreateRunspacePool(1, $concurrency)
    $pool.Open()
    $handles = New-Object System.Collections.Generic.List[object]
    foreach ($item in $rows) {
        if ($item.enc) {
            $handles.Add([pscustomobject]@{ ps = $null; h = $null; pre = [pscustomobject]@{
                id = $item.id; ok = $false; status = 0; elapsedMs = 0
                code = 'key_encrypted'; message = 'the stored key is encrypted; open the editor and enter it to test'; reply = '' } })
            continue
        }
        if (-not $item.url) {
            $handles.Add([pscustomobject]@{ ps = $null; h = $null; pre = [pscustomobject]@{
                id = $item.id; ok = $false; status = 0; elapsedMs = 0
                code = 'url_required'; message = 'this model has no endpoint address'; reply = '' } })
            continue
        }
        $chatUrl = Resolve-ModelProbeUrl $item.url $item.ucp
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($script:groupProbe).AddArgument($chatUrl).AddArgument($item.apiKey).AddArgument($item.id).AddArgument('WorkBuddyKeeper/' + $AppVersion)
        $handles.Add([pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke(); pre = $null })
    }
    foreach ($x in $handles) {
        if ($null -ne $x.pre) { $out.Add($x.pre); continue }
        try {
            $r = $x.ps.EndInvoke($x.h)
            foreach ($one in (To-ItemArray $r)) { if ($null -ne $one) { $out.Add($one) } }
        } catch {
            $out.Add([pscustomobject]@{ id = '?'; ok = $false; status = 0; elapsedMs = 0
                                       code = 'probe_error'; message = [string]$_.Exception.Message; reply = '' })
        } finally { $x.ps.Dispose() }
    }
    $pool.Close(); $pool.Dispose()
    return ,$out.ToArray()
}

function Test-ModelGroupChat([string]$product, [string]$file, $ids, [int]$concurrency) {
    # "Test" on a model-file tab: probe the models INSIDE one models file, each
    # against its OWN url and its OWN stored key.
    #
    # This is not the same thing as Test-ModelBatch. That one takes a single
    # endpoint + key from the batch-import dialog and runs every id against it.
    # A model file is a mixed bag - one entry may be DeepSeek, the next a local
    # gateway with a different key - so the shared-endpoint shape simply does
    # not apply here.
    #
    # $ids may be empty, which means "every model in the file".
    $out = [pscustomobject]@{ ok = $true; error = ''; results = @(); total = 0 }
    $prep = Get-ModelGroupEntries $product $file $ids
    if (-not $prep.ok) { $out.ok = $false; $out.error = $prep.error; return $out }
    $rows = @($prep.entries)
    $out.total = $rows.Count
    if ($rows.Count -eq 0) { return $out }
    $out.results = Test-ModelGroupChatEntries $rows $concurrency
    $okCount = 0
    foreach ($r in $out.results) { if ($r.ok) { $okCount++ } }
    Write-Log ("models group-test: file={0} total={1} ok={2}" -f $file, $out.results.Count, $okCount)
    return $out
}

$script:groupProbe = {
    param($chatUrl, $apiKey, $modelId, $userAgent)
    $res = [pscustomobject]@{ id = $modelId; ok = $false; status = 0; elapsedMs = 0; code = ''; message = ''; reply = '' }
    $req = $null
    try { $req = [Net.WebRequest]::Create($chatUrl) } catch { }
    if ($null -eq $req) { $res.code = 'url_invalid'; $res.message = 'the address could not be parsed'; return $res }
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $payload = @{ model = $modelId; messages = @(@{ role = 'user'; content = 'Reply with OK.' }); max_tokens = 1; stream = $false }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req.Method = 'POST'
        $req.Timeout = 45000
        $req.AllowAutoRedirect = $true
        $req.UserAgent = $userAgent
        $req.Headers['Authorization'] = 'Bearer ' + $apiKey
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
        $resp = $req.GetResponse()
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
        } finally { $resp.Close() }
        $res.status = [int]$resp.StatusCode
        $res.elapsedMs = [int]$sw.ElapsedMilliseconds
        $parsed = $null
        try { $parsed = $body | ConvertFrom-Json } catch { }
        if ($null -eq $parsed) {
            $res.code = 'chat_bad_response'; $res.message = 'the reply is not valid JSON'
            return $res
        }
        # Same permissive rule as every other probe here: 2xx + parseable JSON,
        # and an EMPTY content still passes (max_tokens=1 on a reasoning model
        # spends its token on reasoning_content).
        $errMsg = ''
        $ep = $parsed.PSObject.Properties['error']
        if ($null -ne $ep -and $null -ne $ep.Value) {
            if ($ep.Value -is [string]) { $errMsg = [string]$ep.Value }
            else {
                $m = $ep.Value.PSObject.Properties['message']
                if ($null -ne $m) { $errMsg = [string]$m.Value }
                if (-not $errMsg) { $errMsg = 'the endpoint returned an error' }
            }
        }
        if ($errMsg) { $res.code = 'chat_bad_response'; $res.message = 'HTTP ' + $res.status + ' but the endpoint reported an error: ' + $errMsg; return $res }
        $ch = $parsed.PSObject.Properties['choices']
        if ($null -ne $ch) {
            $first = @($ch.Value)[0]
            if ($null -ne $first) {
                $msg = $first.PSObject.Properties['message']
                if ($null -ne $msg -and $null -ne $msg.Value) {
                    $c = $msg.Value.PSObject.Properties['content']
                    if ($null -ne $c -and $null -ne $c.Value) { $res.reply = [string]$c.Value }
                } else {
                    $dl = $first.PSObject.Properties['delta']
                    if ($null -ne $dl -and $null -ne $dl.Value) {
                        $c = $dl.Value.PSObject.Properties['content']
                        if ($null -ne $c -and $null -ne $c.Value) { $res.reply = [string]$c.Value }
                    }
                }
            }
        }
        $res.ok = $true; $res.code = 'ok'; $res.message = 'model answered'
        return $res
    } catch [Net.WebException] {
        $res.elapsedMs = [int]$sw.ElapsedMilliseconds
        $we = $_.Exception
        if ($null -ne $we.Response) {
            try {
                $res.status = [int]$we.Response.StatusCode
                $sr = New-Object IO.StreamReader($we.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $s = $sr.ReadToEnd(); $sr.Close()
                if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                $res.reply = $s
            } catch { }
        }
        $res.code = 'chat_failed'
        if ($res.status -eq 404) { $res.message = 'HTTP 404 - the model id probably does not exist here' }
        elseif ($res.status -eq 401 -or $res.status -eq 403) { $res.message = 'HTTP ' + $res.status + ' - the key was rejected' }
        elseif ($res.status -eq 429) { $res.message = 'HTTP 429 - rate limited' }
        elseif ($res.status -gt 0) { $res.message = 'HTTP ' + $res.status }
        else { $res.message = [string]$we.Message }
        return $res
    } catch {
        $res.elapsedMs = [int]$sw.ElapsedMilliseconds
        $res.code = 'chat_failed'; $res.message = [string]$_.Exception.Message
        return $res
    }
}

function Get-DbOwnerCount([string]$dbPath, [string]$uid) {
    # Counts only LOCAL rows, deliberately. Every other place that moves a
    # conversation between accounts filters on transport='local' (a cloud row's
    # owner belongs to the server; rewriting the local mirror would just make the
    # sidebar disagree with reality). The count has to use the same filter as the
    # remap it guards, or the check would pass on rows the remap will not touch.
    $db = Open-WbDatabasePath $dbPath
    try {
        $rows = [WbSqlite]::Query($db,
            "SELECT count(*) AS n FROM sessions WHERE user_id=?1 AND transport='local'", @($uid))
    } finally {
        [WbSqlite]::Close($db)
    }
    if (-not $rows.Count) { return 0 }
    return [int]$rows[0]['n']
}

function Get-DbSessionCounts([string]$dbPath) {
    # Whole-database tallies, no account filter: archived and deleted rows are
    # counted too, because "how many conversations are in this backup" is a
    # different question from "how many can I see right now".
    $out = [pscustomobject]@{ total = 0; archived = 0; deleted = 0; cloud = 0; alive = 0 }
    $db = Open-WbDatabasePath $dbPath
    try {
        # archived/deleted only count local rows: cloud conversations are a bucket
        # of their own in the UI and are listed only under the "cloud" chip, so a
        # tombstoned cloud row must not inflate the deleted tally here either.
        $rows = [WbSqlite]::Query($db,
            "SELECT count(*) AS n,
                    sum(CASE WHEN transport='local' AND status='archived' THEN 1 ELSE 0 END) AS arch,
                    sum(CASE WHEN transport='local' AND deleted_at IS NOT NULL AND CAST(deleted_at AS TEXT) <> '-1' THEN 1 ELSE 0 END) AS del,
                    sum(CASE WHEN transport <> 'local' THEN 1 ELSE 0 END) AS cld
             FROM sessions", $null)
    } finally {
        [WbSqlite]::Close($db)
    }
    if ($rows.Count) {
        $r = $rows[0]
        if ($r['n']) { $out.total = [int]$r['n'] }
        if ($r['arch']) { $out.archived = [int]$r['arch'] }
        if ($r['del']) { $out.deleted = [int]$r['del'] }
        if ($r['cld']) { $out.cloud = [int]$r['cld'] }
    }
    $out.alive = $out.total - $out.deleted
    return $out
}

function Test-RemapSafe([string]$dbPath, [string]$oldUid, [string]$newUid) {
    # Rewriting the owner used to be done by replacing bytes in the file, which
    # only worked when the backup had no transaction log next to it. Now that the
    # database is opened through SQLite this restriction is gone: the log is
    # replayed first, then a plain UPDATE runs. So a backup that still carries an
    # unmerged -wal is perfectly fine.
    if (-not $oldUid -or -not $newUid) { return @{ ok = $false; reason = 'no_account'; oldCount = 0; newCount = 0 } }
    if ($oldUid -eq $newUid) { return @{ ok = $false; reason = 'same_account'; oldCount = 0; newCount = 0 } }
    if (-not (Test-Path -LiteralPath $dbPath)) { return @{ ok = $false; reason = 'no_database'; oldCount = 0; newCount = 0 } }
    $oldCount = 0
    $newCount = 0
    try {
        $oldCount = Get-DbOwnerCount $dbPath $oldUid
        $newCount = Get-DbOwnerCount $dbPath $newUid
    } catch {
        return @{ ok = $false; reason = 'db_unreadable'; oldCount = 0; newCount = 0 }
    }
    if ($oldCount -le 0) { return @{ ok = $false; reason = 'owner_not_found'; oldCount = 0; newCount = $newCount } }
    return @{ ok = $true; reason = 'ok'; oldCount = $oldCount; newCount = $newCount }
}

function Invoke-UidRemap([string]$dbPath, [string]$oldUid, [string]$newUid) {
    $db = Open-WbDatabasePath $dbPath
    try {
        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        try {
            # transport='local' is REQUIRED here, and was missing. A cloud row's
            # owner lives on the server; reassigning the local mirror would only
            # desync the sidebar from the account it really belongs to. Every
            # other conversation update in this file already carries this filter,
            # and the switch dialog promises to move local conversations only.
            $n = [WbSqlite]::Exec($db,
                "UPDATE sessions SET user_id=?1 WHERE user_id=?2 AND transport='local'",
                @($newUid, $oldUid))
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
        } catch {
            [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
            throw
        }
        [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
        $chk = [WbSqlite]::Query($db, 'PRAGMA integrity_check', $null)
        if (-not $chk.Count -or [string]$chk[0]['integrity_check'] -ne 'ok') { throw 'integrity_check_failed' }
        Write-Log ("uid remap {0} -> {1} ({2} rows)" -f $oldUid, $newUid, $n)
        return $n
    } finally {
        [WbSqlite]::Close($db)
    }
}

function Set-UidForIds([string]$dbPath, $Ids, [string]$newUid) {
    # Custom restore + "rewrite the owner to the current account": rewrite exactly
    # the conversations the user ticked, whatever account they belonged to.
    # Invoke-UidRemap (by old uid) is not enough here: a backup can hold rows from
    # several accounts - the user may have switched accounts before backing up -
    # and those rows would keep an owner the logged-in account cannot see, even
    # though the user explicitly asked to take them over.
    if (-not $newUid) { throw 'no_current_account' }
    $list = @()
    foreach ($k in $Ids.Keys) { $s = [string]$k; if ($s) { $list += $s } }
    if (-not $list.Count) { return 0 }
    $db = Open-WbDatabasePath $dbPath
    try {
        $total = 0
        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        try {
            $chunk = 400
            for ($i = 0; $i -lt $list.Count; $i += $chunk) {
                $tail = @($list[$i..([Math]::Min($i + $chunk - 1, $list.Count - 1))])
                $ph = @()
                for ($k = 0; $k -lt $tail.Count; $k++) { $ph += ('?{0}' -f ($k + 2)) }
                $inList = ($ph -join ', ')
                # ?1 is the new owner, ?2.. are the ids. transport='local' keeps
                # cloud mirrors alone: their owner lives on the server.
                $total += [WbSqlite]::Exec($db,
                    ("UPDATE sessions SET user_id=?1 WHERE transport='local' AND id IN ({0})" -f $inList),
                    (@($newUid) + $tail))
            }
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
        } catch {
            [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
            throw
        }
        [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
        $chk = [WbSqlite]::Query($db, 'PRAGMA integrity_check', $null)
        if (-not $chk.Count -or [string]$chk[0]['integrity_check'] -ne 'ok') { throw 'integrity_check_failed' }
        Write-Log ("uid rewrite by id -> {0} ({1} rows)" -f $newUid, $total)
        return $total
    } finally {
        [WbSqlite]::Close($db)
    }
}

function Get-RestoreGroup([bool]$exists, [long]$srcBytes, [long]$srcMs, [long]$dstBytes, [long]$dstMs) {
    # GROUPING SUGGESTION ONLY - this is NOT a decision about what to overwrite.
    # Custom restore never lets the backend pick conversations: the user submits
    # an explicit id set (selectedIds) and the backend overwrites exactly those.
    # This helper only stamps one of four labels on a row so the UI can pre-select
    # a sensible default per group. The final choice ALWAYS comes from the user.
    #
    #   backupOnly   - the id is not present locally (exists=false)
    #   backupBetter - backup is BOTH newer AND larger
    #   localBetter  - same timestamp (whatever the size), or strictly older AND smaller
    #   conflict     - the two axes disagree: newer-but-smaller, older-but-bigger
    #
    # "Same timestamp, different size" deliberately sits in localBetter: an equal
    # updated_at means the client last touched both copies at the same moment, so
    # there is no newer side to prefer. Defaulting to "keep local" is the safer
    # suggestion of the two, and it matches what the user asked for.
    if (-not $exists) { return 'backupOnly' }
    if ($srcMs -gt $dstMs -and $srcBytes -gt $dstBytes) { return 'backupBetter' }
    if ($srcMs -eq $dstMs) { return 'localBetter' }
    if ($srcMs -lt $dstMs -and $srcBytes -lt $dstBytes) { return 'localBetter' }
    return 'conflict'
}

function Get-RestorePlan([string]$name, [string]$product) {
    # Read-only survey for custom restore: a FULL list of the conversations that
    # exist in the backup (cloud rows excluded), with the size, time and state of
    # both the backup and the local copy. Never writes anything, and it does NOT
    # decide what to overwrite - the group labels are only default suggestions,
    # the user submits the final id set. Restore-Backup calls this again with the
    # SAME arguments so the list the user saw is the list that gets applied.
    $dir = Join-Path $BackupsDir $name
    if (-not (Test-Path -LiteralPath $dir)) { throw 'backup_missing' }

    $out = [pscustomobject]@{
        items                = @()
        total                = 0
        hasBackupDb          = $false
        backupHasAttachments = $false
        cloudSkipped         = 0
        groups               = [pscustomobject]@{
            conflict     = 0
            backupBetter = 0
            backupOnly   = 0
            localBetter  = 0
        }
    }

    # --- the backup side: read its database, not its manifest ---
    $srcRows = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db')) {
        $out.hasBackupDb = $true
        $stage = $null
        try {
            $stage = New-StagedDb $dir
            $stageDb = Join-Path $stage 'workbuddy.db'
            foreach ($r in (Get-DbSessionsAt $stageDb)) { $srcRows.Add($r) }
        } catch {
            # Swallowing this would return an empty-but-OK plan: the dialog would
            # enable "confirm", the user would submit selections, and custom
            # restore would report success while having done nothing. Let the
            # error reach the dialog so it can show the reason and offer retry.
            Write-Log ('restore plan: backup db unreadable: ' + $_.Exception.Message)
            throw
        } finally { Remove-StagedDb $stage }
    }

    # --- the local side ---
    $local = @{}
    foreach ($s in (Get-SessionsIndex $product -IncludeDeleted)) { $local[[string]$s.id] = $s }
    $localProj = Join-Path (Get-EditionHome $product) 'projects'

    # Does this backup carry attachments? Get-SessionsIndex ALWAYS counts the
    # local attachment folder (its `bytes` is consumed by ~8 read-only callers,
    # so it cannot be changed there). The two sides are therefore aligned HERE,
    # per backup: when the backup carries attachments both sides count the
    # attachment folder; when it does not (includeAttachments=false) the local
    # attachment folder is subtracted below so the two numbers are comparable.
    # Otherwise a backup made without attachments would look smaller than the
    # local copy for every conversation that has attachments, and every size
    # comparison (and therefore every group label) would be wrong.
    $backupHasAtt = $true
    try {
        $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
        if ($null -ne $mf -and $null -ne $mf.PSObject.Properties['includeAttachments']) {
            $backupHasAtt = [bool]$mf.includeAttachments
        }
    } catch { }
    $out.backupHasAttachments = $backupHasAtt

    # Transcript sizes inside the backup. A session's "size" has to mean the same
    # thing on both sides or the comparison is meaningless. When the backup has
    # attachments, both sides count the .jsonl, its rollback file and the
    # attachment folder; when it does not, the attachment folder is left out of
    # the local number too so the two are comparable.
    $srcProj = Join-Path $dir 'projects'
    $items = New-Object System.Collections.Generic.List[object]
    $g = @{ conflict = 0; backupBetter = 0; backupOnly = 0; localBetter = 0 }
    foreach ($row in $srcRows) {
        $sid = [string]$row.id
        # Cloud conversations live on the server; the user asked to see only the
        # backup's own (local) conversations, so leave cloud rows out entirely.
        if ([string]$row.transport -eq 'cloud') { $out.cloudSkipped++; continue }

        $srcBytes = [long]0
        if (Test-Path -LiteralPath $srcProj) {
            foreach ($slugDir in @(Get-ChildItem -LiteralPath $srcProj -Directory -ErrorAction SilentlyContinue)) {
                $cand = Join-Path $slugDir.FullName ($sid + '.jsonl')
                if (Test-Path -LiteralPath $cand) {
                    $srcBytes += (Get-Item -LiteralPath $cand).Length
                    $rb = Join-Path $slugDir.FullName ($sid + '.file-rollback.ndjson')
                    if (Test-Path -LiteralPath $rb) { $srcBytes += (Get-Item -LiteralPath $rb).Length }
                    $att = Join-Path $slugDir.FullName $sid
                    if ($backupHasAtt -and (Test-Path -LiteralPath $att)) { $srcBytes += (Get-FolderSize $att) }
                    break
                }
            }
        }
        $srcMs = [long]$row.updatedMs

        # State fields come from the backup db when present; if an older schema
        # lacks them they simply read back empty/false (Get-DbSessionsAt always
        # returns the properties, defaulted).
        $src = [pscustomobject]@{
            bytes     = $srcBytes
            ms        = $srcMs
            at        = [string](ConvertFrom-Ms $srcMs)
            archived  = [bool]$row.archived
            deleted   = [bool]$row.deleted
            transport = [string]$row.transport
            status    = [string]$row.status
        }

        $exists = $local.ContainsKey($sid)
        $dstBytes = [long]0
        $dstMs = [long]0
        if ($exists) {
            $l = $local[$sid]
            # Match the backup's accounting (see $backupHasAtt above): Get-SessionsIndex
            # unconditionally folds the attachment folder into `bytes`, so subtract it
            # back out when this backup does not carry attachments.
            $localBytes = [long]$l.bytes
            if (-not $backupHasAtt -and $l.hasAttachments) {
                $attDir = Join-Path (Join-Path $localProj ([string]$l.slug)) $sid
                if (Test-Path -LiteralPath $attDir) { $localBytes = $localBytes - (Get-FolderSize $attDir) }
            }
            $dstBytes = $localBytes
            $dstMs = [long]$l.updatedMs
            $dst = [pscustomobject]@{
                bytes     = $dstBytes
                ms        = $dstMs
                at        = [string]$l.updatedAt
                archived  = [bool]$l.archived
                deleted   = [bool]$l.deleted
                transport = [string]$l.transport
                status    = [string]$l.status
                exists    = $true
            }
        } else {
            # Not present locally: exists=false and every other dst field left empty/0.
            $dst = [pscustomobject]@{
                bytes     = [long]0
                ms        = [long]0
                at        = ''
                archived  = $false
                deleted   = $false
                transport = ''
                status    = ''
                exists    = $false
            }
        }

        # Only a grouping suggestion, never a decision (see Get-RestoreGroup).
        $group = Get-RestoreGroup $exists $srcBytes $srcMs $dstBytes $dstMs
        $g[$group]++

        $items.Add([pscustomobject]@{
            id                   = $sid
            title                = [string]$row.title
            src                  = $src
            dst                  = $dst
            group                = $group
            backupHasAttachments = $backupHasAtt
            cloud                = $false
        })
    }
    $out.items = $items.ToArray()
    $out.total = $items.Count
    $out.groups = [pscustomobject]@{
        conflict     = $g.conflict
        backupBetter = $g.backupBetter
        backupOnly   = $g.backupOnly
        localBetter  = $g.localBetter
    }
    return $out
}


function Merge-DbSessions([string]$product, [string]$srcDbPath, $UpdateIds = $null, $SelectedIds = $null) {
    # "Fill in what is missing" for the database: copy the rows that the target
    # does not have yet, leave everything else alone.
    # The two editions may not be on the same schema version, so only the columns
    # that exist on both sides are copied - a missing column simply keeps its
    # default instead of blowing up the whole restore.
    #
    # -UpdateIds turns it into a sync: the rows in that set are refreshed from the
    # backup even though the target already has an id-equal row. Rows outside the
    # set keep the old insert-only behaviour, and nothing is ever deleted either
    # way. Returns insert/update/unchanged counts so the caller can report what
    # actually happened instead of guessing. (Kept for the legacy path; custom
    # restore uses -SelectedIds below, which is strictly narrower.)
    #
    # -SelectedIds is custom restore: restore EXACTLY that id set from the backup
    # and touch NOTHING else. Unlike the plain merge it does NOT insert every
    # missing backup row - an unselected backup-only conversation must stay
    # absent locally, and a local-only conversation must never be deleted. Each
    # selected id is DELETEd (if present locally) then re-INSERTed from the
    # backup, so an existing row is overwritten and an absent one is added, with
    # no double counting between the two. Returns the applied row count.
    $db = Open-WbDatabase $product
    try {
        $dstCols = @([WbSqlite]::Query($db, 'PRAGMA table_info(sessions)', $null) | ForEach-Object { [string]$_['name'] })
        if (-not $dstCols.Count) { throw 'no_sessions_table' }
        $esc = $srcDbPath.Replace("'", "''")
        [void][WbSqlite]::Exec($db, ("ATTACH DATABASE '{0}' AS src" -f $esc), $null)
        try {
            $srcCols = @([WbSqlite]::Query($db, 'PRAGMA src.table_info(sessions)', $null) | ForEach-Object { [string]$_['name'] })
            if (-not $srcCols.Count) { throw 'source_has_no_sessions' }
            $common = @($dstCols | Where-Object { $srcCols -contains $_ })
            if (-not $common.Count) { throw 'no_common_columns' }
            $colList = ($common | ForEach-Object { '"' + $_ + '"' }) -join ', '
            $inserted = 0
            $updated = 0
            $unchanged = 0
            $applied = 0
            [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
            try {
                if ($null -ne $SelectedIds) {
                    # CUSTOM RESTORE: only the ids the user picked. DELETE the
                    # local copy (when one exists) then INSERT the backup's row.
                    # The DELETE is guarded by EXISTS so it only removes a row
                    # that the backup actually has; the INSERT only pulls rows
                    # whose id is in the set. Rows outside the set - local-only
                    # conversations and unselected backup conversations - are
                    # never touched. Same DELETE + INSERT trick as the sync path
                    # (UPDATE ... FROM needs SQLite 3.33+), chunked to stay under
                    # the variable limit. Identifiers come from PRAGMA; id values
                    # are bound as parameters, never interpolated.
                    $ids = @()
                    foreach ($k in $SelectedIds.Keys) { $s = [string]$k; if ($s) { $ids += $s } }
                    if ($ids.Count -gt 0) {
                        $chunk = 400
                        for ($i = 0; $i -lt $ids.Count; $i += $chunk) {
                            $tail = @($ids[$i..([Math]::Min($i + $chunk - 1, $ids.Count - 1))])
                            $ph = @()
                            for ($k = 0; $k -lt $tail.Count; $k++) { $ph += ('?{0}' -f ($k + 1)) }
                            $inList = ($ph -join ', ')
                            [void][WbSqlite]::Exec($db,
                                ("DELETE FROM sessions WHERE id IN ({0}) AND EXISTS (SELECT 1 FROM src.sessions WHERE src.sessions.id = sessions.id)" -f $inList),
                                $tail)
                            $applied += [WbSqlite]::Exec($db,
                                ("INSERT INTO sessions ({0}) SELECT {0} FROM src.sessions WHERE id IN ({1})" -f $colList, $inList),
                                $tail)
                        }
                    }
                } else {
                    # 1. everything the target does not have yet (plain merge and
                    #    the legacy -UpdateIds path both fill in missing rows)
                    $inserted = [WbSqlite]::Exec($db,
                        ("INSERT OR IGNORE INTO sessions ({0}) SELECT {0} FROM src.sessions" -f $colList), $null)
                }

                if ($null -eq $SelectedIds -and $null -ne $UpdateIds) {
                    # 2. the rows the sync chose to overwrite: delete the local
                    #    copy, then take the backup's. DELETE + INSERT rather
                    #    than UPDATE ... FROM because the latter needs SQLite
                    #    3.33+, and winsqlite3.dll is whatever the OS shipped -
                    #    on older Windows that statement would simply be a
                    #    syntax error. Both statements run inside the same
                    #    transaction, so the delete can never be left dangling.
                    #
                    # Identifiers come from PRAGMA (never user input); the id
                    # values are bound as parameters.
                    $ids = @()
                    foreach ($k in $UpdateIds.Keys) { $s = [string]$k; if ($s) { $ids += $s } }
                    if ($ids.Count -gt 0) {
                        # Chunked: one statement per few hundred ids, so a big
                        # account does not hit SQLite's variable limit and the
                        # statement stays reusable within a chunk.
                        $chunk = 400
                        for ($i = 0; $i -lt $ids.Count; $i += $chunk) {
                            $tail = @($ids[$i..([Math]::Min($i + $chunk - 1, $ids.Count - 1))])
                            $ph = @()
                            for ($k = 0; $k -lt $tail.Count; $k++) { $ph += ('?{0}' -f ($k + 1)) }
                            $inList = ($ph -join ', ')
                            $updated += [WbSqlite]::Exec($db,
                                ("DELETE FROM sessions WHERE id IN ({0}) AND EXISTS (SELECT 1 FROM src.sessions WHERE src.sessions.id = sessions.id)" -f $inList),
                                $tail)
                            [void][WbSqlite]::Exec($db,
                                ("INSERT INTO sessions ({0}) SELECT {0} FROM src.sessions WHERE id IN ({1})" -f $colList, $inList),
                                $tail)
                        }
                    }
                    # 3. how many local rows were left untouched.
                    # The count is taken BEFORE the insert above would be
                    # counted in: rows that already existed and were not in the
                    # push set. Counting after the insert made brand-new rows
                    # look like "unchanged", which contradicted the dialog.
                    $chk2 = @([WbSqlite]::Query($db, ("SELECT count(*) AS n FROM sessions WHERE id IN (SELECT id FROM src.sessions)"), $null))
                    if ($chk2.Count) { $unchanged = [int]$chk2[0]['n'] - $updated - $inserted }
                    if ($unchanged -lt 0) { $unchanged = 0 }
                }
                [void][WbSqlite]::Exec($db, 'COMMIT', $null)
            } catch {
                [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
                throw
            }
            [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
            $chk = [WbSqlite]::Query($db, 'PRAGMA integrity_check', $null)
            if (-not $chk.Count -or [string]$chk[0]['integrity_check'] -ne 'ok') { throw 'integrity_check_failed' }
            Write-Log ("db merge: {0} rows inserted from {1} (updated={2} applied={3})" -f $inserted, $srcDbPath, $updated, $applied)
            if ($null -ne $SelectedIds) { return [pscustomobject]@{ applied = $applied } }
            if ($null -ne $UpdateIds) {
                return [pscustomobject]@{ inserted = $inserted; updated = $updated; unchanged = $unchanged }
            }
            return $inserted
        } finally {
            try { [void][WbSqlite]::Exec($db, 'DETACH DATABASE src', $null) } catch { }
        }
    } finally {
        [WbSqlite]::Close($db)
    }
}

# --------------------------------------------------------------------------
# conversations ("sessions" table)
#
# The database is the single source of truth: one row per conversation, with
# user_id = the account that owns it. The client's sidebar only lists rows whose
# user_id matches the account currently logged in and whose deleted_at is null,
# which is exactly what Get-DbSessions returns.
#
# sidebar-list-snapshot.json under <home>\<uid>\ is only a rendering cache the
# client rebuilds from the database on every start - it is not authoritative and
# must not be treated as one.
# --------------------------------------------------------------------------
function Get-DbSessionsAt([string]$dbPath) {
    # Same shape as Get-DbSessions, but for any database file - the live one, or
    # a copy staged out of a backup. Reading a backup through this is what lets
    # the backup viewer show what was really saved instead of trusting the
    # manifest, which only ever recorded what the sidebar had rendered.
    $db = Open-WbDatabasePath $dbPath
    try {
        $rows = [WbSqlite]::Query($db,
            "SELECT id, user_id, title, custom_title, cwd, transport, status, updated_at, deleted_at FROM sessions",
            $null)
    } finally {
        [WbSqlite]::Close($db)
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $title = [string]$r['custom_title']
        if (-not $title) { $title = [string]$r['title'] }
        $updatedMs = [long]0
        if ($r['updated_at']) { [void][long]::TryParse([string]$r['updated_at'], [ref]$updatedMs) }
        # deleted_at is null for local rows and -1 for cloud rows; anything else
        # is the millisecond stamp of the deletion
        $del = $false
        $raw = [string]$r['deleted_at']
        if ($raw -and $raw -ne '-1') { $del = $true }
        # archiving is a separate thing: status becomes 'archived' and deleted_at
        # stays null, so a conversation can be archived, deleted, or both.
        $status = [string]$r['status']
        $list.Add([pscustomobject]@{
            id        = [string]$r['id']
            uid       = [string]$r['user_id']
            title     = $title
            cwd       = [string]$r['cwd']
            transport = [string]$r['transport']
            status    = $status
            archived  = ($status -eq 'archived')
            deleted   = $del
            updatedMs = $updatedMs
        })
    }
    return $list.ToArray()
}

function Get-DbSessions([string]$product) {
    return (Get-DbSessionsAt (Join-Path (Get-EditionHome $product) 'workbuddy.db'))
}

function Copy-DbSnapshot([string]$product, [string]$tag) {
    $edHome = Get-EditionHome $product
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = $stamp + '-' + $product
    if ($tag) { $name = $name + '-' + $tag }
    $dir = Join-Path $DbSnapshotsDir $name
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $n = 0
    foreach ($f in @('workbuddy.db', 'workbuddy.db-wal', 'workbuddy.db-shm')) {
        $src = Join-Path $edHome $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dir $f) -Force
            $n++
        }
    }
    Write-Log ("db snapshot: {0} ({1} files)" -f $dir, $n)
    return $dir
}

function New-StagedDb([string]$srcDir) {
    # Copy a database (plus whatever transaction log sits next to it) into a
    # scratch folder and let SQLite replay that log, so the caller gets one
    # self-contained file it can inspect or rewrite. This is what makes a backup
    # with an unmerged -wal perfectly usable instead of a dead end.
    $srcDb = Join-Path $srcDir 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $srcDb)) { throw 'no_database' }
    $stage = Join-Path $DbSnapshotsDir ('stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $dst = Join-Path $stage 'workbuddy.db'
    Copy-Item -LiteralPath $srcDb -Destination $dst -Force
    foreach ($w in @('workbuddy.db-wal', 'workbuddy.db-shm')) {
        $ws = Join-Path $srcDir $w
        if (Test-Path -LiteralPath $ws) { Copy-Item -LiteralPath $ws -Destination (Join-Path $stage $w) -Force }
    }
    try {
        $db = Open-WbDatabasePath $dst
        try { [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null) }
        finally { [WbSqlite]::Close($db) }
    } catch {
        Write-Log ('stage checkpoint failed: ' + $_.Exception.Message)
    }
    return $stage
}

function Remove-StagedDb([string]$stage) {
    if (-not $stage) { return }
    try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-RecoverCandidates([string]$product) {
    # Three kinds are offered:
    #   live      normal conversations owned by another account, ticked by default
    #   archived  status='archived', owned by another account; ticked by default and
    #             it keeps its archived state (the update only touches user_id)
    #   deleted   deleted_at holds a timestamp. Listed no matter which account owns
    #             them - including the one logged in now - but NOT ticked by
    #             default, because undeleting is a deliberate act.
    # Cloud sessions are skipped on purpose: their owner lives on the server, so
    # rewriting the local row would do nothing but confuse the sidebar.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $cur = Get-CurrentAccount $product
    if (-not $cur) { throw 'no_login_state' }
    $all = Get-SessionsIndex $product -IncludeDeleted
    $list = New-Object System.Collections.Generic.List[object]
    $unattached = 0
    $cloud = 0
    foreach ($s in $all) {
        if ($s.transport -ne 'local') {
            if ($s.uid -and $s.uid -ne $cur.uid -and -not $s.deleted) { $cloud++ }
            continue
        }
        $state = 'live'
        $ord = 0
        if ($s.deleted) {
            $state = 'deleted'
            $ord = 2
        } else {
            if (-not $s.uid) { $unattached++; continue }
            if ($s.uid -eq $cur.uid) { continue }
            if ($s.archived) { $state = 'archived'; $ord = 1 }
        }
        $list.Add([pscustomobject]@{
            id        = [string]$s.id
            title     = [string]$s.title
            slug      = [string]$s.slug
            uid       = [string]$s.uid
            space     = [string]$s.space
            transport = [string]$s.transport
            bytes     = [long]$s.bytes
            updatedMs = [long]$s.updatedMs
            state     = $state
            archived  = [bool]$s.archived
            deleted   = [bool]$s.deleted
            mine      = ([string]$s.uid -eq [string]$cur.uid)
            defaultOn = ($state -ne 'deleted')
            ord       = $ord
        })
    }
    $sorted = @($list | Sort-Object -Property ord, @{ Expression = { $_.updatedMs }; Descending = $true })
    return [pscustomobject]@{
        account    = $cur
        sessions   = $sorted
        unattached = $unattached
        cloud      = $cloud
        archived   = @($sorted | Where-Object { $_.state -eq 'archived' }).Count
        deleted    = @($sorted | Where-Object { $_.state -eq 'deleted' }).Count
    }
}

function Update-SidebarCache([string]$product, $sessions, [string]$newUid) {
    # <home>\<uid>\sidebar-list-snapshot.json is a cache the client rebuilds from
    # the database when it starts. Refresh it anyway so that an already running
    # client does not keep rendering the old owner, and so that a conversation
    # that never made it into any cache still gets an entry.
    $edHome = Get-EditionHome $product
    $want = @{}
    foreach ($s in $sessions) { $want[[string]$s.id] = $s }

    $targetDir = Join-Path $edHome $newUid
    $targetPath = Join-Path $targetDir 'sidebar-list-snapshot.json'
    $targetSnap = Read-JsonFile $targetPath
    $items = New-Object System.Collections.Generic.List[object]
    $have = @{}
    if ($targetSnap -and $targetSnap.items) {
        foreach ($it in @($targetSnap.items)) {
            if ($it.id) { $have[[string]$it.id] = $true }
            $items.Add($it)
        }
    }
    $moved = 0

    foreach ($d in @(Get-ChildItem -LiteralPath $edHome -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq $newUid) { continue }
        $p = Join-Path $d.FullName 'sidebar-list-snapshot.json'
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $snap = Read-JsonFile $p
        if (-not $snap -or -not $snap.items) { continue }
        $keep = New-Object System.Collections.Generic.List[object]
        $dropped = 0
        foreach ($it in @($snap.items)) {
            $iid = ''
            if ($it.id) { $iid = [string]$it.id }
            if ($iid -and $want.ContainsKey($iid)) {
                $dropped++
                if (-not $have.ContainsKey($iid)) {
                    $items.Add($it)
                    $have[$iid] = $true
                }
            } else {
                $keep.Add($it)
            }
        }
        if ($dropped -gt 0) {
            $snap.items = $keep.ToArray()
            $snap.savedAt = (Get-NowMs)
            Write-JsonFile $p $snap
            $moved += $dropped
        }
    }

    foreach ($s in $sessions) {
        $sid = [string]$s.id
        if ($have.ContainsKey($sid)) { continue }
        # a deleted conversation must not reappear in the sidebar, and an archived
        # one belongs in the archive section, which the client builds from the
        # database itself - so neither gets a fresh sidebar entry here
        if ($s.deleted -or $s.archived) { continue }
        $space = $null
        if ($s.cwd) { $space = [pscustomobject]@{ type = 'local'; name = [string]$s.cwd } }
        $items.Add([pscustomobject]@{
            id                 = $sid
            title              = [string]$s.title
            state              = 'idle'
            transport          = 'local'
            kind               = 'task'
            lastActivityAt     = [long]$s.updatedMs
            isPinned           = $false
            conversationOrigin = 'local'
            updatedAt          = [long]$s.updatedMs
            space              = $space
        })
        $have[$sid] = $true
        $moved++
    }

    $out = $targetSnap
    if (-not $out) { $out = [pscustomobject]@{ version = 1; savedAt = 0; items = @() } }
    $out.items = $items.ToArray()
    $out.savedAt = (Get-NowMs)
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Write-JsonFile $targetPath $out
    return $moved
}

function Invoke-RecoverSessions([string]$product, [string[]]$ids, [bool]$Backup = $true) {
    # Hand conversations over to the account that is logged in now.
    #
    # Ownership is one column - sessions.user_id - so this is a plain UPDATE run
    # through the same SQLite engine the client uses. That matters: the database
    # is in WAL mode, so writing the file behind SQLite's back (or deleting the
    # -wal next to it) loses the change as soon as the client flushes its page
    # cache. The client has to be closed first, then the update is committed and
    # checkpointed, then the client is started again.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $cur = Get-CurrentAccount $product
    if (-not $cur) { throw 'no_login_state' }
    $newUid = [string]$cur.uid
    $edHome = Get-EditionHome $product
    $dbPath = Join-Path $edHome 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $dbPath)) { throw 'no_database' }

    $rows = Get-DbSessions $product
    $map = @{}
    foreach ($s in $rows) { $map[$s.id] = $s }

    $targets = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($id in @($ids)) {
        $sid = [string]$id
        if (-not $sid) { continue }
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        if (-not $map.ContainsKey($sid)) { continue }
        $s = $map[$sid]
        # archived conversations are recoverable and keep their archived state.
        # Deleted ones are recoverable from ANY account (including the one logged
        # in now) and come back alive, because that is the whole point of picking
        # them in the dialog.
        if ($s.transport -ne 'local') { continue }
        if (-not $s.deleted) {
            if (-not $s.uid) { continue }
            if ($s.uid -eq $newUid) { continue }
        }
        $targets.Add($s)
    }
    if ($targets.Count -eq 0) { throw 'nothing_to_recover' }

    $procName = Get-ProductProc $product
    $wasRunning = ((Get-ClientProcesses $procName).Count -gt 0)
    if ($wasRunning) {
        [void](Stop-Client $procName)
        for ($i = 0; $i -lt 40; $i++) {
            if ((Get-ClientProcesses $procName).Count -eq 0) { break }
            Start-Sleep -Milliseconds 150
        }
    }

    # A FULL backup, not just the database: if the change turns out wrong you want
    # the transcript files and the account snapshots back as well, not a lone .db.
    # Aborts on failure for the same reason as the purge above: the user asked
    # for this safety net, and recovering rewrites ownership in the database.
    $snapName = ''
    if ($Backup) {
        try {
            $m = New-Backup $true 'pre-recover' '' $product
            if ($m) { $snapName = [string]$m.name }
        } catch {
            Write-Log ('pre-recover backup failed, aborting: ' + $_.Exception.Message)
            throw ('backup_failed: ' + (Get-ErrMessage $_.Exception))
        }
    }

    $failure = ''
    $db = $null
    try {
        $db = Open-WbDatabase $product
        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        try {
            foreach ($s in $targets) {
                if ($s.deleted) {
                    # undelete: the row keeps its content, only the tombstone goes
                    [void][WbSqlite]::Exec($db,
                        "UPDATE sessions SET user_id=?1, deleted_at=NULL WHERE id=?2 AND transport='local'",
                        @($newUid, [string]$s.id))
                } else {
                    # the previous owner is part of the predicate, so running this
                    # twice cannot move a conversation that already moved
                    [void][WbSqlite]::Exec($db,
                        "UPDATE sessions SET user_id=?1 WHERE id=?2 AND user_id=?3 AND transport='local'",
                        @($newUid, [string]$s.id, [string]$s.uid))
                }
            }
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
        } catch {
            [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
            throw
        }
        # fold the write-ahead log into the main file so the client cannot come
        # back up on a stale page cache
        [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($db -ne $null) { [WbSqlite]::Close($db) }
    }
    if ($failure) {
        Write-Log ('recover failed: ' + $failure)
        throw ('recover_failed: ' + $failure)
    }

    # verify by reading the database back, not by trusting the update count
    $after = Get-DbSessions $product
    $byId = @{}
    foreach ($s in $after) { $byId[$s.id] = $s }
    $recovered = 0
    $undeleted = 0
    $missed = New-Object System.Collections.Generic.List[string]
    $done = New-Object System.Collections.Generic.List[object]
    foreach ($s in $targets) {
        if ($byId.ContainsKey($s.id) -and $byId[$s.id].uid -eq $newUid -and -not $byId[$s.id].deleted) {
            $recovered++
            if ($s.deleted) { $undeleted++ }
            $done.Add($byId[$s.id])
        } else {
            $missed.Add([string]$s.id)
        }
    }

    # the sidebar cache has to be refreshed from the post-update rows: a row that
    # was deleted a moment ago is a normal conversation now
    $sidebar = 0
    try { $sidebar = Update-SidebarCache $product $done.ToArray() $newUid } catch {
        Write-Log ('sidebar cache refresh failed: ' + $_.Exception.Message)
    }

    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}
    Write-Log ("recover: edition={0} targets={1} recovered={2} undeleted={3} missed={4} sidebar={5}" -f $product, $targets.Count, $recovered, $undeleted, $missed.Count, $sidebar)
    return [pscustomobject]@{
        ok         = $true
        edition    = $product
        requested  = $targets.Count
        recovered  = $recovered
        undeleted  = $undeleted
        missed     = $missed.ToArray()
        sidebar    = $sidebar
        snapshot   = $snapName
        restarted  = $false
        wasRunning = $wasRunning
    }
}

# --------------------------------------------------------------------------
# conversation state + permanent delete
#
# Three states are shown as one column, but the table stores them in two:
#   status = 'archived'                      -> sits in the client's archive
#   deleted_at = millisecond stamp           -> tombstoned, hidden everywhere
#   deleted_at = -1                          -> cloud row marker, NOT a tombstone
#                                       (Get-SessionsIndex already reports it as
#                                        deleted=$false, so it never lands here)
# A row can be archived and deleted at the same time, which is why turning one
# flag on does not clear the other unless the target state says so.
# --------------------------------------------------------------------------
function Fork-Session([string]$product, [string]$id) {
    # Create a fork (independent duplicate) of one local conversation: a new row
    # with a fresh UUID plus its own transcript / rollback / attachment files,
    # leaving the original untouched. The fork's display title gets the source
    # conversation's last-updated timestamp appended so the two are tellable
    # apart in the client sidebar.
    #
    # Requires the client to be closed, same as every other direct db write.
    # session_usage is deliberately NOT copied: the fork starts with zero usage.
    # The transcript lines themselves are copied verbatim - whether the client
    # tolerates a copied transcript whose lines may embed the OLD session id is
    # exactly what this feature is meant to find out; the original stays intact
    # either way, and a bad fork can simply be deleted.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    if (-not $id) { throw 'params_required' }
    if ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0) { throw 'client_running' }
    $home_ = Get-EditionHome $product
    $dbPath = Join-Path $home_ 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $dbPath)) { throw 'no_database' }

    $db = Open-WbDatabasePath $dbPath
    $copied = New-Object System.Collections.Generic.List[string]
    try {
        $rows = [WbSqlite]::Query($db, 'SELECT id, title, custom_title, transport, updated_at FROM sessions WHERE id=?1', @($id))
        if (-not $rows.Count) { throw 'session_not_found' }
        # cloud rows live on the server; a fork of the mirror row would have no
        # transcript behind it
        if ([string]$rows[0]['transport'] -ne 'local') { throw 'cloud_session' }

        $srcMs = [long]0
        [void][long]::TryParse([string]$rows[0]['updated_at'], [ref]$srcMs)
        $base = [string]$rows[0]['custom_title']
        if (-not $base) { $base = [string]$rows[0]['title'] }
        # Drop a trailing timestamp of OUR OWN making before adding a new one.
        # Forking a fork would otherwise pile " (date)" up forever - it already
        # did in real data ("... (2026-11-11 23:38) (2026-11-11 23:38)") - and
        # once the name is long enough the pile-up pushes the real title out and
        # the truncation can even cut through the middle of a timestamp.
        $base = [regex]::Replace($base, '(\s*\(\d{4}-\d{2}-\d{2} \d{2}:\d{2}\))+\s*$', '')
        $base = $base.Trim()
        if (-not $base) { $base = 'Untitled' }
        # updated_at <= 0 has no readable time; appending " ()" would be worse
        # than no suffix at all.
        $dt = ConvertFrom-Ms $srcMs
        $stamp = ''
        if ($dt) { $stamp = ' (' + $dt + ')' }
        # Cap the combined title. 60 characters: the client trims its own
        # automated titles around 50, so anything longer is never actually read.
        # The stamp is always kept whole; the name is shortened and marked with
        # a trailing "..." (ASCII - this file must stay pure ASCII).
        $maxTitle = 60
        if ($base.Length + $stamp.Length -gt $maxTitle) {
            $keep = [Math]::Max(1, $maxTitle - $stamp.Length - 3)   # 3 for the dots
            # Never split a surrogate pair: a truncated emoji lands in the db as
            # U+FFFD (WbSqlite writes UTF-8 with a replacement fallback), and the
            # ".Substring" here counts UTF-16 units, not characters.
            if ($keep -lt $base.Length -and [char]::IsHighSurrogate($base[$keep - 1])) { $keep-- }
            $base = $base.Substring(0, [Math]::Max(1, $keep)) + '...'
        }
        $newTitle = $base + $stamp
        $newId = [guid]::NewGuid().ToString()

        # Locate the transcript files BEFORE writing anything, so a missing file
        # is just a db-only fork (some old conversations have no transcript at
        # all) rather than a half-done operation.
        $projDir = Join-Path $home_ 'projects'
        $srcJsonl = ''
        $srcSlug = ''
        if (Test-Path -LiteralPath $projDir) {
            foreach ($slugDir in @(Get-ChildItem -LiteralPath $projDir -Directory -ErrorAction SilentlyContinue)) {
                $cand = Join-Path $slugDir.FullName ($id + '.jsonl')
                if (Test-Path -LiteralPath $cand) {
                    $srcSlug = $slugDir.Name
                    $srcJsonl = $cand
                    break
                }
            }
        }

        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        $committed = $false
        try {
            # Copy every column of the source row except id, which gets the new
            # UUID. Columns come from PRAGMA, never from user input; both ids are
            # bound as parameters. custom_title is then set to the stamped title
            # (the client prefers custom_title for display; the original title
            # column keeps its value).
            $cols = @([WbSqlite]::Query($db, 'PRAGMA table_info(sessions)', $null) |
                      ForEach-Object { [string]$_['name'] } |
                      Where-Object { $_ -ne 'id' })
            if (-not $cols.Count) { throw 'no_sessions_table' }
            $colList = ($cols | ForEach-Object { '"' + $_ + '"' }) -join ', '
            [void][WbSqlite]::Exec($db,
                ("INSERT INTO sessions (id, {0}) SELECT ?1, {0} FROM sessions WHERE id=?2" -f $colList),
                @($newId, $id))
            if ($cols -contains 'custom_title') {
                [void][WbSqlite]::Exec($db,
                    'UPDATE sessions SET custom_title=?1 WHERE id=?2',
                    @($newTitle, $newId))
            }

            # Copy the transcript files under the NEW id next to the original.
            # A failure here rolls the db insert back and removes whatever the
            # copy already wrote, so the destination never keeps a fork with no
            # transcript behind it.
            if ($srcJsonl) {
                $slugDir = Join-Path $projDir $srcSlug
                $dstJsonl = Join-Path $slugDir ($newId + '.jsonl')
                Copy-Item -LiteralPath $srcJsonl -Destination $dstJsonl -Force
                $copied.Add($dstJsonl)
                $rb = Join-Path $slugDir ($id + '.file-rollback.ndjson')
                if (Test-Path -LiteralPath $rb) {
                    $dstRb = Join-Path $slugDir ($newId + '.file-rollback.ndjson')
                    Copy-Item -LiteralPath $rb -Destination $dstRb -Force
                    $copied.Add($dstRb)
                }
                $att = Join-Path $slugDir $id
                if (Test-Path -LiteralPath $att) {
                    $dstAtt = Join-Path $slugDir $newId
                    # Strict copy: Copy-Tree swallows non-terminating errors on
                    # purpose (attachment caches tolerate gaps in other flows),
                    # but a fork must not report success with a partial
                    # attachment directory. Errors must reach the rollback.
                    # The destination folder is registered BEFORE any child is
                    # copied, so a child copy failing partway still removes the
                    # half-filled directory (not just fully copied files).
                    New-Item -ItemType Directory -Path $dstAtt -Force | Out-Null
                    $copied.Add($dstAtt)
                    # Strict copy: a fork must not report success with a partial
                    # attachment directory, so errors reach the rollback. The
                    # source id is passed as the skip name: a self-nested copy
                    # inside the source is an artifact of the old restore code
                    # and must not be duplicated into the fork.
                    Copy-Tree $att $dstAtt '' -Strict
                }
            }
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
            $committed = $true
        } catch {
            # ROLLBACK only when the transaction is actually still open: a
            # failure AFTER the commit (nothing does that today, but keep the
            # order safe) must not turn a committed fork into a reported
            # failure, and a failing ROLLBACK must not skip the file cleanup.
            if (-not $committed) {
                try { [void][WbSqlite]::Exec($db, 'ROLLBACK', $null) } catch { Write-Log ('fork rollback: ' + $_.Exception.Message) }
            }
            foreach ($p in $copied) {
                try {
                    if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).PSIsContainer) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
                    elseif (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
                } catch { Write-Log ('fork cleanup: ' + $_.Exception.Message) }
            }
            throw
        }
        # Close-out after a successful commit, same as the other direct writers
        # (Set-SessionState, purge, recover): flush the WAL so the client / our
        # own index see the fork immediately, and drop the 10s session cache so
        # the page reload after this dialog closes does not serve stale totals.
        # A failure here is logged only - the fork IS committed, reporting it as
        # a failure would invite a retry that creates a second copy.
        try { [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null) }
        catch { Write-Log ('fork checkpoint: ' + $_.Exception.Message) }
        $script:SessionCache = @{}
        $script:SessionCacheAt = @{}
        return [pscustomobject]@{ ok = $true; id = $newId; title = $newTitle }
    } finally {
        [WbSqlite]::Close($db)
    }
}

function Set-SessionState([string]$product, [string]$id, [string]$target) {
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    if (-not $id) { throw 'params_required' }
    if (@('visible', 'archived', 'deleted') -notcontains $target) { throw 'bad_state' }

    # The client holds the database open and flushes its own page cache. A write
    # done while it runs is silently undone by the next checkpoint, so the column
    # is read-only in the UI while the client is up - and enforced here too.
    if ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0) { throw 'client_running' }

    $dbPath = Join-Path (Get-EditionHome $product) 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $dbPath)) { throw 'no_database' }

    $state = 'visible'
    $db = Open-WbDatabasePath $dbPath
    try {
        $rows = [WbSqlite]::Query($db, 'SELECT id, transport, status, deleted_at FROM sessions WHERE id=?1', @($id))
        if (-not $rows.Count) { throw 'session_not_found' }
        # cloud rows are owned and stored on the server; the local row is a mirror
        if ([string]$rows[0]['transport'] -ne 'local') { throw 'cloud_session' }

        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        try {
            switch ($target) {
                'visible' {
                    # clearing the archive flag needs a normal status back. The old
                    # one is not recorded anywhere; 'completed' is the harmless
                    # value the client itself keeps for an idle conversation.
                    [void][WbSqlite]::Exec($db,
                        "UPDATE sessions SET deleted_at=NULL, status=CASE WHEN status='archived' THEN 'completed' ELSE status END WHERE id=?1 AND transport='local'",
                        @($id))
                }
                'archived' {
                    [void][WbSqlite]::Exec($db,
                        "UPDATE sessions SET status='archived', deleted_at=NULL WHERE id=?1 AND transport='local'",
                        @($id))
                }
                'deleted' {
                    [void][WbSqlite]::Exec($db,
                        "UPDATE sessions SET deleted_at=?2 WHERE id=?1 AND transport='local'",
                        @($id, [string](Get-NowMs)))
                }
            }
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
        } catch {
            [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
            throw
        }
        # fold the log in, otherwise the client restarts on a stale page cache
        [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
        $after = [WbSqlite]::Query($db, 'SELECT status, deleted_at FROM sessions WHERE id=?1', @($id))
        if ($after.Count) {
            $raw = [string]$after[0]['deleted_at']
            if ($raw -and $raw -ne '-1') { $state = 'deleted' }
            elseif ([string]$after[0]['status'] -eq 'archived') { $state = 'archived' }
        }
    } finally {
        [WbSqlite]::Close($db)
    }

    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}
    Write-Log ("session state: {0} -> {1} ({2})" -f $id, $target, $state)
    return $state
}

function Get-DeletedSessions([string]$product) {
    # Everything that carries a real tombstone, no matter which account owns it.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $all = Get-SessionsIndex $product -IncludeDeleted
    $cur = Get-CurrentAccount $product
    $curUid = ''
    if ($cur) { $curUid = [string]$cur.uid }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in $all) {
        if (-not $s.deleted) { continue }
        if ($s.transport -ne 'local') { continue }
        $mine = ($curUid -ne '' -and [string]$s.uid -eq $curUid)
        $list.Add([pscustomobject]@{
            id        = [string]$s.id
            title     = [string]$s.title
            slug      = [string]$s.slug
            uid       = [string]$s.uid
            space     = [string]$s.space
            bytes     = [long]$s.bytes
            updatedMs = [long]$s.updatedMs
            archived  = [bool]$s.archived
            mine      = $mine
        })
    }
    # current account first, then newest first: the rows people usually want gone
    # are their own recent mistakes
    $sorted = @($list | Sort-Object -Property @{ Expression = { $_.mine }; Descending = $true }, @{ Expression = { $_.updatedMs }; Descending = $true })
    return [pscustomobject]@{
        account  = $cur
        sessions = $sorted
        count    = $sorted.Count
    }
}

function Invoke-PurgeSessions([string]$product, [string[]]$ids, [bool]$Backup = $true) {
    # Permanent. The row, the transcript, the tool-cache folder and the rollback
    # log all go: keeping any of them would leave a conversation that no longer
    # shows up but still occupies disk, which is the exact confusion this dialog
    # is meant to end.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $edHome = Get-EditionHome $product
    $dbPath = Join-Path $edHome 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $dbPath)) { throw 'no_database' }

    # Re-check every id against the database: a dialog left open for a while must
    # not delete a conversation that was brought back to life in the meantime.
    $rows = Get-DbSessions $product
    $map = @{}
    foreach ($s in $rows) { $map[$s.id] = $s }
    $targets = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($id in @($ids)) {
        $sid = [string]$id
        if (-not $sid) { continue }
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        if (-not $map.ContainsKey($sid)) { continue }
        $s = $map[$sid]
        if (-not $s.deleted) { continue }
        if ($s.transport -ne 'local') { continue }
        $targets.Add($s)
    }
    if ($targets.Count -eq 0) { throw 'nothing_to_purge' }

    $procName = Get-ProductProc $product
    $wasRunning = ((Get-ClientProcesses $procName).Count -gt 0)
    if ($wasRunning) {
        [void](Stop-Client $procName)
        for ($i = 0; $i -lt 40; $i++) {
            if ((Get-ClientProcesses $procName).Count -eq 0) { break }
            Start-Sleep -Milliseconds 150
        }
    }

    # A FULL backup first, same as a restore: a lone .db would not bring the
    # transcripts back if the wrong rows were ticked.
    #
    # A failed backup ABORTS THE WHOLE PURGE. The user ticked the backup-first box
    # themselves, so the safety net is what they asked for - going on to delete
    # rows and transcripts would destroy data they believed was covered, and
    # nothing can bring it back. Nothing destructive has happened at this point
    # (the client was closed, nothing else), so stopping is safe; the user can
    # untick the box if they really want to delete without a backup.
    $snapName = ''
    if ($Backup) {
        try {
            $m = New-Backup $true 'pre-purge' '' $product
            if ($m) { $snapName = [string]$m.name }
        } catch {
            Write-Log ('pre-purge backup failed, aborting: ' + $_.Exception.Message)
            throw ('backup_failed: ' + (Get-ErrMessage $_.Exception))
        }
    }

    # 1. database rows
    $failure = ''
    $db = $null
    $removedRows = 0
    try {
        $db = Open-WbDatabasePath $dbPath
        [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
        try {
            foreach ($s in $targets) {
                try { [void][WbSqlite]::Exec($db, 'DELETE FROM session_usage WHERE session_id=?1', @([string]$s.id)) } catch { }
                $n = [WbSqlite]::Exec($db,
                    "DELETE FROM sessions WHERE id=?1 AND transport='local' AND deleted_at IS NOT NULL AND CAST(deleted_at AS TEXT) <> '-1'",
                    @([string]$s.id))
                $removedRows += $n
            }
            [void][WbSqlite]::Exec($db, 'COMMIT', $null)
        } catch {
            [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
            throw
        }
        [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
        $chk = [WbSqlite]::Query($db, 'PRAGMA integrity_check', $null)
        if (-not $chk.Count -or [string]$chk[0]['integrity_check'] -ne 'ok') { throw 'integrity_check_failed' }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($db -ne $null) { [WbSqlite]::Close($db) }
    }
    if ($failure) {
        Write-Log ('purge failed: ' + $failure)
        throw ('purge_failed: ' + $failure)
    }

    # 2. transcript files, tool-cache folders, rollback logs
    $projects = Join-Path $edHome 'projects'
    $freed = [long]0
    $removedFiles = 0
    $idset = @{}
    foreach ($s in $targets) { $idset[[string]$s.id] = $true }
    if (Test-Path -LiteralPath $projects) {
        $dirs = @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)
        foreach ($s in $targets) {
            $sid = [string]$s.id
            $slugs = @()
            if ($s.slug) { $slugs += [string]$s.slug }
            if (-not $slugs.Count) { foreach ($d in $dirs) { $slugs += $d.Name } }
            foreach ($slug in $slugs) {
                $base = Join-Path (Join-Path $projects $slug) $sid
                foreach ($f in @(($base + '.jsonl'), ($base + '.file-rollback.ndjson'))) {
                    if (-not (Test-Path -LiteralPath $f)) { continue }
                    try {
                        # Measure first, add afterwards: adding before the delete
                        # would report the space as reclaimed even when the
                        # removal throws (read-only file, AV lock, trash policy).
                        $len = [long](Get-Item -LiteralPath $f).Length
                        Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                        $freed += $len
                        $removedFiles++
                    } catch { Write-Log ('purge file failed: ' + $f + ' ' + $_.Exception.Message) }
                }
                if (Test-Path -LiteralPath $base) {
                    try {
                        $len = [long](Get-FolderSize $base)
                        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction Stop
                        $freed += $len
                        $removedFiles++
                    } catch { Write-Log ('purge folder failed: ' + $base + ' ' + $_.Exception.Message) }
                }
            }
        }
    }

    # 3. sidebar caches: no account may keep rendering a ghost row
    $sidebar = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $edHome -Directory -ErrorAction SilentlyContinue)) {
        $p = Join-Path $d.FullName 'sidebar-list-snapshot.json'
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $snap = Read-JsonFile $p
        if (-not $snap -or -not $snap.items) { continue }
        $keep = New-Object System.Collections.Generic.List[object]
        $drop = 0
        foreach ($it in @($snap.items)) {
            $iid = ''
            if ($it.id) { $iid = [string]$it.id }
            if ($iid -and $idset.ContainsKey($iid)) { $drop++ } else { $keep.Add($it) }
        }
        if ($drop -gt 0) {
            $snap.items = $keep.ToArray()
            $snap.savedAt = (Get-NowMs)
            Write-JsonFile $p $snap
            $sidebar += $drop
        }
    }

    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}
    Write-Log ("purge: edition={0} requested={1} rows={2} files={3} sidebar={4}" -f $product, $targets.Count, $removedRows, $removedFiles, $sidebar)
    return [pscustomobject]@{
        ok         = $true
        edition    = $product
        requested  = $targets.Count
        purged     = $removedRows
        files      = $removedFiles
        freed      = $freed
        sidebar    = $sidebar
        snapshot   = $snapName
        wasRunning = $wasRunning
        skipped    = ($targets.Count - $removedRows)
    }
}

# --------------------------------------------------------------------------
# client process control
# --------------------------------------------------------------------------
function Get-ClientProcesses([string]$procName) {
    if ($NoProcessControl) { return @() }
    if ($procName -eq '*') {
        return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'WorkBuddy' -or $_.ProcessName -eq 'WorkBuddyAI' })
    }
    return @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
}

function Get-CachedExePath([string]$product) {
    $state = Read-JsonFile $StatePath
    if ($state -and $state.exes -and $state.exes.$product) { return [string]$state.exes.$product }
    return ''
}

function Set-CachedExePath([string]$product, [string]$path) {
    if (-not $product -or -not $path) { return }
    $exes = @{}
    $state = Read-JsonFile $StatePath
    if ($state -and $state.exes) {
        foreach ($pp in $state.exes.PSObject.Properties) { $exes[$pp.Name] = [string]$pp.Value }
    }
    if ($exes.ContainsKey($product) -and $exes[$product] -eq $path) { return }
    $exes[$product] = $path
    Write-JsonFile $StatePath ([pscustomobject]@{ exes = $exes })
}

function Find-ClientExe([string]$product) {
    # Where the client lives is a property of the machine, not of this tool, so it
    # is looked up every time instead of being remembered as a fixed path:
    #   1. the exe of a client that is already running  (most reliable)
    #   2. the Windows installer records (App Paths / Uninstall)
    #   3. a Start Menu shortcut
    #   4. the usual per-user install folders, built from environment variables
    #   5. a previously discovered path, but only if it still exists
    # Anything remembered is therefore only a hint for this machine, and is thrown
    # away the moment the file is gone.
    $procName = Get-ProductProc $product
    $exeName = $procName + '.exe'

    foreach ($p in (Get-ClientProcesses $procName)) {
        try { if ($p.Path) { Set-CachedExePath $product $p.Path; return $p.Path } } catch { }
    }

    $found = Get-ExeFromAppPaths $exeName
    if ($found) { Set-CachedExePath $product $found; return $found }

    $found = Get-ExeFromUninstall $exeName
    if ($found) { Set-CachedExePath $product $found; return $found }

    $found = Get-ExeFromStartMenu $exeName $procName
    if ($found) { Set-CachedExePath $product $found; return $found }

    $cached = Get-CachedExePath $product
    if ($cached -and (Test-Path -LiteralPath $cached)) { return $cached }

    # usual install locations, all relative to the environment
    $candidates = New-Object System.Collections.Generic.List[string]
    $bases = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs')) }
    if ($env:ProgramFiles) { $bases.Add($env:ProgramFiles) }
    if (${env:ProgramFiles(x86)}) { $bases.Add(${env:ProgramFiles(x86)}) }
    if ($env:APPDATA) { $bases.Add((Join-Path $env:APPDATA 'Local\Programs')) }
    foreach ($b in $bases) {
        foreach ($sub in @($procName, ($procName + ' AI'), ($procName + 'AI'), ($procName + ' International'))) {
            $candidates.Add((Join-Path (Join-Path $b $sub) $exeName))
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { Set-CachedExePath $product $c; return $c }
    }

    # last resort: one level of folders under the same bases, matched by name
    foreach ($b in $bases) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        try {
            $hit = Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like ($procName + '*') } |
                   ForEach-Object { Join-Path $_.FullName $exeName } |
                   Where-Object { Test-Path -LiteralPath $_ } |
                   Select-Object -First 1
            if ($hit) { Set-CachedExePath $product $hit; return $hit }
        } catch { }
    }
    return ''
}

function Get-ExeFromAppPaths([string]$exeName) {
    # HKCU/HKLM "App Paths" is what the shell itself uses for "start WorkBuddy"
    $keys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $exeName,
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $exeName,
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\' + $exeName
    )
    foreach ($k in $keys) {
        try {
            $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            $v = [string]$item.GetValue('')
            $v = $v.Trim('"')
            if ($v -and (Test-Path -LiteralPath $v)) { return $v }
        } catch { }
    }
    return ''
}

function Get-ExeFromUninstall([string]$exeName) {
    # Uninstall entries carry InstallLocation / DisplayIcon; match on the file name
    # rather than on DisplayName, so it works in any UI language.
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        $items = @()
        try { $items = @(Get-ItemProperty -Path $r -ErrorAction SilentlyContinue) } catch { continue }
        foreach ($it in $items) {
            if (-not $it) { continue }
            $loc = ''
            try { $loc = [string]$it.InstallLocation } catch { }
            if ($loc) {
                $cand = Join-Path ($loc.Trim('"').TrimEnd('\')) $exeName
                if (Test-Path -LiteralPath $cand) { return $cand }
            }
            $icon = ''
            try { $icon = [string]$it.DisplayIcon } catch { }
            if ($icon) {
                $p = ($icon.Trim('"') -split ',')[0].Trim().Trim('"')
                if ($p -and [IO.Path]::GetFileName($p) -ieq $exeName -and (Test-Path -LiteralPath $p)) { return $p }
            }
        }
    }
    return ''
}

function Get-ExeFromStartMenu([string]$exeName, [string]$procName) {
    $roots = New-Object System.Collections.Generic.List[string]
    if ($env:APPDATA) { $roots.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')) }
    if ($env:ProgramData) { $roots.Add((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')) }
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { return '' }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $lnks = @()
        try {
            $lnks = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like ('*' + $procName + '*') })
        } catch { continue }
        foreach ($l in $lnks) {
            try {
                $t = [string]$shell.CreateShortcut($l.FullName).TargetPath
                if ($t -and [IO.Path]::GetFileName($t) -ieq $exeName -and (Test-Path -LiteralPath $t)) { return $t }
            } catch { }
        }
    }
    return ''
}

function Stop-Client([string]$procName) {
    if ($NoProcessControl) { return $false }
    $procs = Get-ClientProcesses $procName
    if (-not $procs -or $procs.Count -eq 0) { return $false }
    Write-Log ("stopping client: {0} ({1} processes)" -f $procName, $procs.Count)
    foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch { } }
    Start-Sleep -Milliseconds 1200
    foreach ($p in (Get-ClientProcesses $procName)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ClientProcesses $procName).Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }
    return $true
}

function Start-Client([string]$product) {
    if ($NoProcessControl) { return @{ started = $false; exe = ''; reason = 'process_control_disabled' } }
    $exe = Find-ClientExe $product
    if (-not $exe) { return @{ started = $false; exe = ''; reason = 'exe_not_found' } }
    $dir = Split-Path -Parent $exe
    Start-Process -FilePath $exe -WorkingDirectory $dir | Out-Null
    $deadline = (Get-Date).AddSeconds(25)
    $procName = Get-ProductProc $product
    while ((Get-Date) -lt $deadline) {
        if ((Get-ClientProcesses $procName).Count -gt 0) { return @{ started = $true; exe = $exe } }
        Start-Sleep -Milliseconds 400
    }
    return @{ started = $false; exe = $exe; reason = 'start_timeout' }
}

function Switch-Account([string]$product, [string]$uid, [bool]$Restart = $true, [bool]$MoveSessions = $false) {
    # A switch is always scoped to one edition: the snapshot must exist inside that
    # edition's profile folder, and only that edition's client and .info file are touched.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $infoSrc = Get-ProfileInfoPath $product $uid
    if (-not (Test-Path -LiteralPath $infoSrc)) { throw 'profile_missing' }
    $meta = Read-JsonFile (Get-ProfileMetaPath $product $uid)

    # the account we are leaving, captured before the .info file is replaced
    $prev = Get-CurrentAccount $product
    $prevUid = ''
    if ($prev) { $prevUid = [string]$prev.uid }

    $wasRunning = ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0)
    # only touch the client of the product line we are switching
    [void](Stop-Client (Get-ProductProc $product))

    # Save the login state AFTER the client has stopped, not before.
    #
    # The client rotates the refresh token on every renewal and invalidates the
    # previous one. Copying .info while the client is still up (which is what
    # this used to do) can therefore snapshot a token that the client revokes
    # during the 1.2 s before the force kill, or while it writes its state on
    # shutdown - and the snapshot then buys the user a "please log in again" for
    # the very account this step exists to keep. Stopped first, the file on disk
    # is the settled one.
    #
    # Still a hard prerequisite: the whole point of switching is that the old
    # account must not be lost, so a failure here aborts the switch instead of
    # dropping a login we could not back up.
    #
    # Only "there is no login to save" may be swallowed. Anything else (an
    # antivirus lock, a full disk) means the snapshot was NOT taken, and
    # carrying on would overwrite the live .info a few lines below with the
    # target profile - leaving the old account's rotated refresh token only in
    # .bak-before-switch, which the next switch overwrites. That is exactly the
    # "please log in again" this step exists to prevent, so re-throw instead.
    try {
        [void](Save-Profile $product)
    } catch {
        $why = $_.Exception.Message
        if ($why -notmatch 'no_login_state') {
            Write-Log ('save before switch failed: ' + $why)
            throw 'save_before_switch_failed'
        }
        Write-Log 'skip saving current login (none)'
    }

    $dst = Get-InfoPath $product
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination ($dst + '.bak-before-switch') -Force }
    Copy-Item -LiteralPath $infoSrc -Destination $dst -Force
    # Copy-Item keeps the source timestamp; the freshly written login state must look newest
    try { (Get-Item -LiteralPath $dst).LastWriteTime = Get-Date } catch { }
    Write-Log ("switched to {0} {1}" -f $product, $uid)

    # Optional: bring every conversation of the account we just left along. This
    # runs after the client is closed and before it is started, so the new owner
    # is already on disk when the sidebar is built from the database.
    $moved = 0
    $moveError = ''
    if ($MoveSessions -and $prevUid -and $prevUid -ne $uid) {
        $dbPath = Join-Path (Get-EditionHome $product) 'workbuddy.db'
        if (Test-Path -LiteralPath $dbPath) {
            $moving = @()
            try {
                # assign first, then filter: piping the wrapped return value
                # straight into Where-Object would hand it the whole array
                $idx = Get-SessionsIndex $product -IncludeDeleted
                $moving = @($idx | Where-Object { [string]$_.uid -eq $prevUid })
            } catch { $moving = @() }
            try {
                $moved = Invoke-UidRemap $dbPath $prevUid $uid
                $script:SessionCache = @{}
                $script:SessionCacheAt = @{}
                if ($moving.Count -gt 0) {
                    try { [void](Update-SidebarCache $product $moving $uid) } catch {
                        Write-Log ('sidebar cache after move failed: ' + $_.Exception.Message)
                    }
                }
            } catch {
                $moveError = $_.Exception.Message
                Write-Log ('move sessions failed: ' + $moveError)
            }
        } else {
            $moveError = 'no_database'
        }
    }

    if ($Restart) {
        $start = Start-Client $product
    } else {
        # "switch only": the login state is replaced but the client stays closed
        $start = @{ started = $false; exe = ''; reason = 'restart_skipped' }
    }
    $res = [pscustomobject]@{
        ok             = $true
        product        = $product
        edition        = $product
        uid            = $uid
        uinMask        = ''
        restarted      = $start.started
        exe            = $start.exe
        wasRunning     = $wasRunning
        skippedRestart = ($start.started -eq $false)
        moved          = $moved
        movedFrom      = $prevUid
        moveError      = $moveError
        reason         = ''
    }
    if ($meta) { $res.uinMask = (Mask-Uin ([string]$meta.uin)) }
    if (-not $start.started) { $res.reason = [string]$start.reason }
    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}
    return $res
}

function Clear-Login([string]$product, [bool]$Restart = $true) {
    # "log in with a new account": keep the current login state in profiles first
    # (so the old account is not lost), then take the .info away so the client
    # shows its login screen again.
    if (-not (Test-Edition $product)) { throw 'unknown_edition' }
    $dst = Get-InfoPath $product
    if (-not (Test-Path -LiteralPath $dst)) { throw 'not_logged_in' }

    $wasRunning = ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0)
    [void](Stop-Client (Get-ProductProc $product))

    # Stop the client first, then save. Compared with saving while it is still
    # running, this avoids snapshotting a refresh token the client is about to
    # rotate away (it invalidates the previous token on every renewal, and it
    # also writes its state during shutdown). Same reasoning as Switch-Account.
    #
    # The whole point of "log in a new account" is that the old one must not be
    # lost, so saving the current login state is a hard prerequisite: if it fails
    # we stop here instead of clearing a login we could not back up.
    $saved = $null
    try { $saved = Save-Profile $product } catch {
        Write-Log ('save before logout failed: ' + $_.Exception.Message)
        throw 'save_before_logout_failed'
    }

    # the copy in profiles\<product>\<uid>.info is the backup, so the live file is
    # simply removed - no second copy left behind. Do not trust the cmdlet result:
    # some environments wrap Remove-Item and still report an error after deleting,
    # so the only thing that matters is whether the file is actually gone.
    try { Remove-Item -LiteralPath $dst -Force -ErrorAction Stop } catch { }
    if (Test-Path -LiteralPath $dst) {
        Write-Log 'logout failed: login state is still there'
        throw 'logout_failed'
    }
    Write-Log ("cleared login state: {0}" -f $dst)

    if ($Restart) {
        $start = Start-Client $product
    } else {
        $start = @{ started = $false; exe = ''; reason = 'restart_skipped' }
    }
    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}
    return [pscustomobject]@{
        ok             = $true
        product        = $product
        edition        = $product
        restarted      = $start.started
        exe            = $start.exe
        wasRunning     = $wasRunning
        skippedRestart = ($start.started -eq $false)
        savedUid       = $(if ($saved) { [string]$saved.uid } else { '' })
        savedUinMask   = $(if ($saved) { Mask-Uin ([string]$saved.uin) } else { '' })
        reason         = [string]$start.reason
    }
}

# --------------------------------------------------------------------------
# sessions on disk
# --------------------------------------------------------------------------
function Get-SessionsIndex([string]$product, [switch]$IncludeDeleted) {
    # One entry per conversation, joined with whatever the transcript file on disk
    # weighs. Titles and owners come from the database - the per-account
    # sidebar-list-snapshot.json is only a rendering cache and regularly lags
    # behind (or is missing entries entirely), so it cannot be trusted for either.
    #
    # Deleted conversations are hidden by default because the client hides them.
    # "Recover conversations" needs to see them too, so it asks for them.
    if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
    $edHome = Get-EditionHome $product

    $cached = $script:SessionCache[$product]
    $cachedAt = $script:SessionCacheAt[$product]
    if ($cached -and $cachedAt -and ((Get-Date) - $cachedAt).TotalSeconds -lt 10) {
        if ($IncludeDeleted) { return ,$cached }
        return ,@($cached | Where-Object { -not $_.deleted })
    }

    $rows = @()
    try { $rows = Get-DbSessions $product } catch {
        Write-Log ('db read failed: ' + $_.Exception.Message)
        $rows = @()
    }

    $projects = Join-Path $edHome 'projects'
    $files = @{}
    if (Test-Path -LiteralPath $projects) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                if ($f.Name -like '*.file-rollback.*') { continue }
                $sid = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                if ($sid -notmatch '^[0-9a-fA-F]{8}-') { continue }
                $files[$sid] = @{
                    slug = $dir.Name
                    len  = [long]$f.Length
                    time = $f.LastWriteTimeUtc
                }
            }
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in $rows) {
        $sid = [string]$r.id
        $seen[$sid] = $true
        $bytes = [long]0
        $hasAtt = $false
        $hasFile = $files.ContainsKey($sid)
        $slug = ''
        $updatedMs = [long]$r.updatedMs
        if ($hasFile) {
            $fi = $files[$sid]
            $slug = [string]$fi.slug
            $bytes = [long]$fi.len
            $sdir = Join-Path (Join-Path $projects $slug) $sid
            if (Test-Path -LiteralPath $sdir) { $hasAtt = $true; $bytes += (Get-FolderSize $sdir) }
            $rb = Join-Path (Join-Path $projects $slug) ($sid + '.file-rollback.ndjson')
            if (Test-Path -LiteralPath $rb) { $bytes += (Get-Item -LiteralPath $rb).Length }
            if (-not $updatedMs) { $updatedMs = (ConvertTo-Ms $fi.time) }
        }
        $list.Add([pscustomobject]@{
            id             = $sid
            slug           = $slug
            edition        = $product
            title          = [string]$r.title
            uid            = [string]$r.uid
            space          = [string]$r.cwd
            transport      = [string]$r.transport
            status         = [string]$r.status
            archived       = [bool]$r.archived
            deleted        = [bool]$r.deleted
            bytes          = $bytes
            updatedMs      = $updatedMs
            updatedAt      = (ConvertFrom-Ms $updatedMs)
            hasAttachments = $hasAtt
            hasFile        = $hasFile
        })
    }

    # Only when the database cannot be read at all do we fall back to the raw
    # transcript files. They are not a reliable list on their own: the two
    # editions share the projects tree in places, so files belonging to the other
    # edition turn up here with no row and no owner, which reads as "unknown".
    if (-not $rows.Count) {
        foreach ($sid in @($files.Keys)) {
            $fi = $files[$sid]
            $slug = [string]$fi.slug
            $bytes = [long]$fi.len
            $sdir = Join-Path (Join-Path $projects $slug) $sid
            if (Test-Path -LiteralPath $sdir) { $bytes += (Get-FolderSize $sdir) }
            $list.Add([pscustomobject]@{
                id             = $sid
                slug           = $slug
                edition        = $product
                title          = ''
                uid            = ''
                space          = ''
                transport      = 'local'
                status         = ''
                archived       = $false
                deleted        = $false
                bytes          = $bytes
                updatedMs      = (ConvertTo-Ms $fi.time)
                updatedAt      = (ConvertFrom-Ms (ConvertTo-Ms $fi.time))
                hasAttachments = (Test-Path -LiteralPath $sdir)
                hasFile        = $true
            })
        }
    }

    $sorted = @($list | Sort-Object -Property updatedMs -Descending)
    $script:SessionCache[$product] = $sorted
    $script:SessionCacheAt[$product] = Get-Date
    if ($IncludeDeleted) { return ,$sorted }
    return ,@($sorted | Where-Object { -not $_.deleted })
}

function Get-SessionStats([string]$product) {
    if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
    $all = Get-SessionsIndex $product   # returns a real array; do not wrap with @() (would nest)
    # Cloud conversations are not local: their transcript lives on the server and
    # their row here is only a mirror. The card is titled "local conversations",
    # so every number on it counts local rows only - otherwise "conversations",
    # "visible" and "archived" would each be summing a different thing and the
    # three would not add up. Cloud rows are listed under "all conversations ->
    # cloud" instead.
    $arr = @($all | Where-Object { [string]$_.transport -eq 'local' })
    $bytes = 0
    foreach ($s in $arr) { $bytes += $s.bytes }
    $cur = Get-CurrentAccount $product
    $mine = 0
    $archivedMine = 0
    if ($cur) {
        foreach ($s in $arr) {
            if ($s.uid -ne $cur.uid) { continue }
            $mine++
            # archived conversations are still this account's, they just live in
            # the client's archive section instead of the sidebar
            if ($s.archived) { $archivedMine++ }
        }
    }
    return [pscustomobject]@{
        edition      = $product
        total        = $arr.Count
        bytes        = $bytes
        mine         = $mine
        archivedMine = $archivedMine
        unattached   = @($arr | Where-Object { -not $_.uid }).Count
    }
}

# --------------------------------------------------------------------------
# backups
# --------------------------------------------------------------------------
$script:BackupCountCache = @{}

function Get-BackupLocalCount([string]$name) {
    # How many conversations the backup actually holds, cloud rows excluded -
    # the number the "conversations" column is supposed to show. manifest.json
    # cannot answer it: it was written from the sidebar, so archived and deleted
    # conversations (and every cloud row) are missing from it.
    #
    # Counting means staging the copy, so the answer is memoised against the
    # database file's size and timestamp. A backup never changes once it is made,
    # so in practice each one is counted once per run.
    #
    # Returns -1 when there is no readable database, and the caller falls back to
    # the manifest count.
    $dir = Join-Path $BackupsDir $name
    $dbFile = Join-Path $dir 'workbuddy.db'
    if (-not (Test-Path -LiteralPath $dbFile)) { return -1 }
    $fi = Get-Item -LiteralPath $dbFile
    $key = $name + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
    if ($script:BackupCountCache.ContainsKey($key)) { return [int]$script:BackupCountCache[$key] }
    $stage = $null
    $n = -1
    try {
        $stage = New-StagedDb $dir
        $c = Get-DbSessionCounts (Join-Path $stage 'workbuddy.db')
        $n = [int]$c.total - [int]$c.cloud
    } catch {
        Write-Log ('backup count failed: ' + $name + ': ' + $_.Exception.Message)
        $n = -1
    } finally {
        Remove-StagedDb $stage
    }
    if ($n -ge 0) { $script:BackupCountCache[$key] = $n }
    return $n
}

function Get-BackupMeta([string]$name) {
    $dir = Join-Path $BackupsDir $name
    $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
    if (-not $mf) { return $null }
    $sessions = @()
    if ($mf.sessions) { $sessions = @($mf.sessions) }
    $total = 0
    if ($mf.totalBytes) { $total = [long]$mf.totalBytes }
    $createdMs = 0
    if ($mf.createdAtMs) { $createdMs = [long]$mf.createdAtMs }
    $acctUid = ''; $acctUin = ''; $acctProduct = ''
    if ($mf.account) {
        if ($mf.account.uid) { $acctUid = [string]$mf.account.uid }
        if ($mf.account.uin) { $acctUin = [string]$mf.account.uin }
        if ($mf.account.product) { $acctProduct = [string]$mf.account.product }
    }
    # older backups have no edition field; fall back to the account's product line
    $edition = ''
    if ($mf.edition) { $edition = [string]$mf.edition }
    elseif ($acctProduct) { $edition = $acctProduct }
    if (-not (Test-Edition $edition)) { $edition = '' }
    $edHome = ''
    if ($mf.home) { $edHome = [string]$mf.home }
    elseif ($edition) { $edHome = (Get-EditionHome $edition) }
    return [pscustomobject]@{
        name               = $name
        edition            = $edition
        home               = $edHome
        createdAt          = (ConvertFrom-Ms $createdMs)
        createdAtMs        = $createdMs
        sessionCount       = $sessions.Count
        # Conversations actually in the backup (all states, cloud excluded).
        # -1 = no readable database, so the count is unknown and sessionCount is
        # the only thing left to show.
        localCount         = (Get-BackupLocalCount $name)
        fileCount          = [long]$mf.fileCount
        totalBytes         = $total
        accountUid         = $acctUid
        accountUinMask     = (Mask-Uin $acctUin)
        accountProduct     = $acctProduct
        includeAttachments = [bool]$mf.includeAttachments
        auto               = [bool]$mf.auto
        tag                = [string]$mf.tag
        hasDatabase        = [bool]$mf.hasDatabase
        note               = [string]$mf.note
    }
}

function Get-Backups {
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $BackupsDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $BackupsDir -Directory -ErrorAction SilentlyContinue)) {
            $m = Get-BackupMeta $d.Name
            if ($m) { $list.Add($m) }
        }
    }
    return ,@($list | Sort-Object -Property createdAtMs -Descending)
}

function New-Backup([bool]$includeAttachments, [string]$tag, [string]$note, [string]$product) {
    if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
    $edHome = Get-EditionHome $product
    if (-not (Test-Path -LiteralPath $edHome)) { throw 'workbuddy_home_missing' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $prefix = ''
    if ($tag) { $prefix = $tag + '-' }
    $name = $prefix + $stamp
    $dir = Join-Path $BackupsDir $name
    $n = 2
    while (Test-Path -LiteralPath $dir) { $name = $prefix + $stamp + '-' + $n; $dir = Join-Path $BackupsDir $name; $n++ }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $fileCount = 0
    $totalBytes = 0

    # 1. database
    $dbNames = @('workbuddy.db', 'workbuddy.db-wal', 'workbuddy.db-shm')
    $dbCopied = @()
    foreach ($n2 in $dbNames) {
        $src = Join-Path $edHome $n2
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dir $n2) -Force
            $fileCount++
            $totalBytes += (Get-Item -LiteralPath $src).Length
            $dbCopied += $n2
        }
    }

    # 2. sessions
    # Deleted conversations are included on purpose. Deleting a conversation in
    # the client only marks the row - the transcript stays on disk - so leaving
    # them out here produced a backup that carried the row but not the text: the
    # viewer showed "record only" and a restore could not bring the words back.
    # It mattered most for the snapshot taken right before a purge, which exists
    # precisely to make those conversations recoverable.
    $all = Get-SessionsIndex $product -IncludeDeleted
    $sessionEntries = New-Object System.Collections.Generic.List[object]
    foreach ($s in $all) {
        $srcDir = Join-Path (Join-Path $edHome 'projects') $s.slug
        $dstDir = Join-Path (Join-Path $dir 'projects') $s.slug
        # A row with no transcript on disk has no slug; do not create a projects
        # directory for it. The entry still goes into the manifest, it just has
        # nothing to copy.
        if ($s.slug -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

        $jsonl = Join-Path $srcDir ($s.id + '.jsonl')
        if (Test-Path -LiteralPath $jsonl) {
            Copy-Item -LiteralPath $jsonl -Destination (Join-Path $dstDir ($s.id + '.jsonl')) -Force
            $fileCount++
            $totalBytes += (Get-Item -LiteralPath $jsonl).Length
        }
        $rb = Join-Path $srcDir ($s.id + '.file-rollback.ndjson')
        if (Test-Path -LiteralPath $rb) {
            Copy-Item -LiteralPath $rb -Destination (Join-Path $dstDir ($s.id + '.file-rollback.ndjson')) -Force
            $fileCount++
            $totalBytes += (Get-Item -LiteralPath $rb).Length
        }
        if ($includeAttachments -and $s.hasAttachments) {
            $attSrc = Join-Path $srcDir $s.id
            $attDst = Join-Path $dstDir $s.id
            # Faithful copy: a backup must never drop a file, so the nested
            # folders left by the old restore code are carried as they are. The
            # count and the size are taken from the copy so they describe what
            # the backup actually contains.
            Copy-Tree $attSrc $attDst
            $inner = @(Get-ChildItem -LiteralPath $attDst -Recurse -File -Force -ErrorAction SilentlyContinue)
            $fileCount += $inner.Count
            $totalBytes += (Get-FolderSize $attDst)
        }
        $sessionEntries.Add([pscustomobject]@{
            id        = $s.id
            slug      = $s.slug
            title     = $s.title
            uid       = $s.uid
            bytes     = $s.bytes
            updatedAt = $s.updatedAt
            space     = $s.space
        })
    }

    # 3. per-account sidebar snapshots (titles / pinned state)
    $usersDir = Join-Path $dir 'users'
    foreach ($d in @(Get-ChildItem -LiteralPath $edHome -Directory -ErrorAction SilentlyContinue)) {
        $snap = Join-Path $d.FullName 'sidebar-list-snapshot.json'
        if (Test-Path -LiteralPath $snap) {
            $t = Join-Path $usersDir $d.Name
            if (-not (Test-Path -LiteralPath $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
            Copy-Item -LiteralPath $snap -Destination (Join-Path $t 'sidebar-list-snapshot.json') -Force
            $fileCount++
            $totalBytes += (Get-Item -LiteralPath $snap).Length
        }
    }

    $cur = Get-CurrentAccount $product
    $acct = [pscustomobject]@{ uid = ''; uin = ''; product = '' }
    if ($cur) { $acct = [pscustomobject]@{ uid = $cur.uid; uin = $cur.uin; product = $cur.product } }

    $manifest = [pscustomobject]@{
        format             = 1
        appVersion         = $AppVersion
        name               = $name
        tag                = $tag
        note               = $note
        edition            = $product
        home               = $edHome
        createdAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        createdAtMs        = (Get-NowMs)
        account            = $acct
        includeAttachments = $includeAttachments
        auto               = [bool]$tag
        hasDatabase        = ($dbCopied -contains 'workbuddy.db')
        dbFiles            = $dbCopied
        fileCount          = $fileCount
        totalBytes         = $totalBytes
        sessions           = $sessionEntries.ToArray()
    }
    Write-JsonFile (Join-Path $dir 'manifest.json') $manifest
    Write-Log ("backup created: {0} edition={1} sessions={2} bytes={3}" -f $name, $product, $sessionEntries.Count, $totalBytes)
    return (Get-BackupMeta $name)
}

function Get-BackupSessions([string]$name, [string]$edition = '') {
    $dir = Join-Path $BackupsDir $name
    $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
    if (-not $mf) { throw 'manifest_missing' }
    # Same labelling as the database rows: this list is what the viewer falls
    # back to when the backup holds no readable database, and the account
    # filter has to read the same either way.
    if (-not $edition) {
        if ($mf.edition) { $edition = [string]$mf.edition }
        elseif ($mf.account -and $mf.account.product) { $edition = [string]$mf.account.product }
        if (-not (Test-Edition $edition)) { $edition = '' }
    }
    $nickMap = Get-NicknameMap
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($mf.sessions)) {
        $uid = [string]$s.uid
        $nick = ''
        if ($uid) {
            if ($edition) {
                $nk = $edition + ':' + $uid
                if ($nickMap.ContainsKey($nk)) { $nick = [string]$nickMap[$nk] }
            } else {
                $nick = Find-NicknameAny $nickMap $uid
            }
        }
        $list.Add([pscustomobject]@{
            id        = [string]$s.id
            slug      = [string]$s.slug
            title     = [string]$s.title
            uid       = $uid
            shortUid  = (Get-DisplayName $uid)
            nickname  = $nick
            space     = [string]$s.space
            bytes     = [long]$s.bytes
            updatedAt = [string]$s.updatedAt
        })
    }
    return ,$list.ToArray()
}

function Get-BackupDbDetail([string]$name, [string]$edition = '') {
    # What the backup really contains, read from the copy of the database inside
    # it rather than from manifest.json. The manifest was written from the
    # sidebar, so it never mentions archived or deleted conversations (and says
    # nothing at all about cloud rows).
    #
    # The database is staged first so a backup carrying an unmerged -wal gives
    # the same answer as one that was checkpointed before being copied.
    #
    # edition is only needed to resolve nicknames: they are stored per
    # product:uid, so the viewer has to ask for the product the backup came
    # from rather than the one that happens to be in front.
    $dir = Join-Path $BackupsDir $name
    if (-not $edition) {
        $mfEd = Read-JsonFile (Join-Path $dir 'manifest.json')
        if ($mfEd) {
            if ($mfEd.edition) { $edition = [string]$mfEd.edition }
            elseif ($mfEd.account -and $mfEd.account.product) { $edition = [string]$mfEd.account.product }
        }
        if (-not (Test-Edition $edition)) { $edition = '' }
    }
    $nickMap = Get-NicknameMap
    $out = [pscustomobject]@{
        counts   = [pscustomobject]@{ total = 0; archived = 0; deleted = 0; cloud = 0; alive = 0 }
        sessions = @()
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db'))) { return $out }

    $stage = $null
    try {
        $stage = New-StagedDb $dir
        $stageDb = Join-Path $stage 'workbuddy.db'
        $out.counts = Get-DbSessionCounts $stageDb
        $rows = Get-DbSessionsAt $stageDb
    } catch {
        Write-Log ('backup db detail failed: ' + $_.Exception.Message)
        return $out
    } finally {
        Remove-StagedDb $stage
    }

    # Sizes come from the backup's own projects tree. A conversation whose
    # transcript was not included simply reports 0 bytes rather than vanishing:
    # the row exists, that is worth showing.
    $projects = Join-Path $dir 'projects'
    $files = @{}
    if (Test-Path -LiteralPath $projects) {
        foreach ($d in @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                if ($f.Name -like '*.file-rollback.*') { continue }
                $files[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = @{ slug = $d.Name; len = [long]$f.Length }
            }
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $sid = [string]$r.id
        $bytes = [long]0
        $slug = ''
        if ($files.ContainsKey($sid)) {
            $fi = $files[$sid]
            $slug = [string]$fi.slug
            $bytes = [long]$fi.len
            $sdir = Join-Path (Join-Path $projects $slug) $sid
            if (Test-Path -LiteralPath $sdir) { $bytes += (Get-FolderSize $sdir) }
            $rb = Join-Path (Join-Path $projects $slug) ($sid + '.file-rollback.ndjson')
            if (Test-Path -LiteralPath $rb) { $bytes += (Get-Item -LiteralPath $rb).Length }
        }
        $state = 'visible'
        if ($r.deleted) { $state = 'deleted' }
        elseif ($r.archived) { $state = 'archived' }
        elseif ([string]$r.transport -ne 'local') { $state = 'cloud' }
        $uid = [string]$r.uid
        $nick = ''
        if ($uid) {
            if ($edition) {
                $nk = $edition + ':' + $uid
                if ($nickMap.ContainsKey($nk)) { $nick = [string]$nickMap[$nk] }
            } else {
                $nick = Find-NicknameAny $nickMap $uid
            }
        }
        $list.Add([pscustomobject]@{
            id        = $sid
            title     = [string]$r.title
            slug      = $slug
            space     = [string]$r.cwd
            uid       = $uid
            shortUid  = (Get-DisplayName $uid)
            nickname  = $nick
            transport = [string]$r.transport
            state     = $state
            archived  = [bool]$r.archived
            deleted   = [bool]$r.deleted
            cloud     = ([string]$r.transport -ne 'local')
            bytes     = $bytes
            updatedMs = [long]$r.updatedMs
            hasFile   = $files.ContainsKey($sid)
        })
    }
    $out.sessions = $list.ToArray()
    return $out
}

function Restore-Backup([string]$name, [string]$mode, [bool]$remap, [string]$targetEdition, $CustomIds = $null) {
    $dir = Join-Path $BackupsDir $name
    if (-not (Test-Path -LiteralPath $dir)) { throw 'backup_missing' }
    $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
    if (-not $mf) { throw 'manifest_missing' }

    # Which edition produced the backup
    $sourceEdition = ''
    if ($mf.edition) { $sourceEdition = [string]$mf.edition }
    elseif ($mf.account -and $mf.account.product) { $sourceEdition = [string]$mf.account.product }
    if (-not (Test-Edition $sourceEdition)) { $sourceEdition = Get-ActiveEdition }

    # Which edition to write into. Normally the source edition itself; the caller may
    # explicitly ask for another one (cross edition restore), which is allowed but
    # carries a compatibility risk: the two clients may not share a schema version.
    $product = $sourceEdition
    $crossEdition = $false
    if ($targetEdition -and (Test-Edition $targetEdition) -and $targetEdition -ne $sourceEdition) {
        $product = $targetEdition
        $crossEdition = $true
    }
    $edHome = Get-EditionHome $product

    # Custom restore: resolve the user's id set against the SAME full plan the
    # dialog showed (cloud rows excluded), BEFORE touching anything. Ids outside
    # the backup, duplicates and cloud ids are simply ignored. The counts come
    # from the plan so they match the list the user saw even when the backup has
    # no database at all.
    $validSelected = @{}
    $customPushed = 0
    $customAdded = 0
    $customKept = 0
    if ($mode -eq 'custom') {
        if ($null -eq $CustomIds) { $CustomIds = @{} }
        $plan = Get-RestorePlan $name $product
        foreach ($item in @($plan.items)) {
            $iid = [string]$item.id
            if ($CustomIds.ContainsKey($iid)) { $validSelected[$iid] = $true }
        }
        foreach ($item in @($plan.items)) {
            $iid = [string]$item.id
            if (-not $validSelected.ContainsKey($iid)) { continue }
            if ($item.dst.exists) { $customPushed++ } else { $customAdded++ }
        }
        $customKept = [int]$plan.total - $validSelected.Count

        # Nothing selected (or every submitted id was bogus): do absolutely
        # nothing - no client shutdown, no pre-restore snapshot, no writes.
        if ($validSelected.Count -eq 0) {
            return [pscustomobject]@{
                ok            = $true
                mode          = $mode
                edition       = $product
                sourceEdition = $sourceEdition
                crossEdition  = $crossEdition
                home          = $edHome
                files         = 0
                merged        = 0
                customPushed  = 0
                customAdded   = 0
                customKept    = $customKept
                sessions      = @($mf.sessions).Count
                remapDone     = $false
                remapReason   = ''
                preBackup     = ''
                restarted     = $false
                clientExe     = ''
                clientWasOpen = $false
            }
        }
    }

    $procName = Get-ProductProc $product

    $wasRunning = ((Get-ClientProcesses $procName).Count -gt 0)
    if ($wasRunning) {
        [void](Stop-Client $procName)
        Start-Sleep -Milliseconds 600
    }
    # The plan read above may have filled the 10-second session cache, and
    # New-Backup picks transcript / attachment files from that index. A
    # conversation the client created between the scan and the shutdown would be
    # missing its FILES while its db row IS in the safety backup (that copy reads
    # the database directly) - an incomplete rollback point. Drop the cache so the
    # snapshot rescans the stopped client's real state.
    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}

    # safety net: snapshot the current state first.
    # A cross edition restore always takes one, even in merge mode, because it may
    # mix data from two different clients.
    # Custom mode takes one too, unconditionally: it OVERWRITES the conversations
    # the user selected, so it is as destructive as a full restore on those rows
    # even though it leaves every other conversation alone.
    # A failed snapshot ABORTS: everything after this point overwrites or merges
    # into workbuddy.db and copies files in. Restoring is the one operation the
    # user cannot hand-undo, so it must not proceed without the rollback point it
    # was promised. Nothing has been touched yet, so stopping here is clean.
    $pre = $null
    if ($mode -eq 'full' -or $mode -eq 'custom' -or $crossEdition) {
        # A destination that has never been used (fresh install / new machine) has
        # no edition home at all - that is an EMPTY state, not an error. Create the
        # directory so the safety snapshot below can take an empty backup (the
        # rollback point it promises), and so the custom seeding path further down
        # is actually reachable. Real backup failures still abort.
        if (-not (Test-Path -LiteralPath $edHome)) { New-Item -ItemType Directory -Path $edHome -Force | Out-Null }
        try {
            $pre = New-Backup ([bool]$mf.includeAttachments) 'pre-restore' '' $product
            # An empty destination (fresh install / never-used edition home) gets a
            # snapshot WITHOUT a database file - New-Backup only copies a db that
            # exists. Full-restoring such a snapshot later would skip the db
            # replace step, so the conversations a custom/merge restore seeded (or
            # a full restore installed) would survive, even though the rollback
            # reports success. Fix: build an EMPTY database from the backup's own
            # schema (stage it, wipe its session rows) and put it into the
            # snapshot, so "restore the pre-restore backup" really does return the
            # destination to its pre-restore (empty) state.
            if ((Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db')) -and
                -not (Test-Path -LiteralPath (Join-Path $edHome 'workbuddy.db'))) {
                $stage2 = $null
                try {
                    $stage2 = New-StagedDb $dir
                    $sdb = Join-Path $stage2 'workbuddy.db'
                    $db2 = $null
                    try {
                        $db2 = Open-WbDatabasePath $sdb
                        [void][WbSqlite]::Exec($db2, 'BEGIN IMMEDIATE', $null)
                        try {
                            try { [void][WbSqlite]::Exec($db2, 'DELETE FROM session_usage', $null) } catch { }   # session_usage is optional: older backups may not have the table
                            [void][WbSqlite]::Exec($db2, 'DELETE FROM sessions', $null)
                            [void][WbSqlite]::Exec($db2, 'COMMIT', $null)
                        } catch { [void][WbSqlite]::Exec($db2, 'ROLLBACK', $null); throw }
                    } finally { if ($null -ne $db2) { [WbSqlite]::Close($db2) } }
                    $preDir = Join-Path $BackupsDir ([string]$pre.name)
                    Copy-Item -LiteralPath $sdb -Destination (Join-Path $preDir 'workbuddy.db') -Force
                    $preMfPath = Join-Path $preDir 'manifest.json'
                    $preMf = Read-JsonFile $preMfPath
                    if ($null -ne $preMf) {
                        $preMf | Add-Member -NotePropertyName hasDatabase -NotePropertyValue $true -Force
                        Write-JsonFile $preMfPath $preMf
                    }
                } finally { if ($null -ne $stage2) { Remove-StagedDb $stage2 } }
            }
        } catch {
            Write-Log ('pre-restore backup failed, aborting: ' + $_.Exception.Message)
            throw ('backup_failed: ' + (Get-ErrMessage $_.Exception))
        }
    }

    $restored = 0
    $merged = 0
    # $validSelected and the custom* counts were resolved above (before any
    # write); nothing to recompute here. The old time-based sync decided the
    # overwrite set here from an automatic verdict - custom restore does not.
    $remapDone = $false
    $remapReason = ''
    $hasWal = (Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db-wal'))

    # The database is handled the same way in BOTH modes: stage a clean copy
    # (which replays any unmerged -wal), optionally rewrite the owner, then either
    # replace the target database or merge the missing rows into it.
    # Merge used to skip the database entirely, which made a cross edition restore
    # copy transcript files that nothing pointed at - the conversations stayed
    # invisible no matter how many times you ran it.
    $dbSrc = Join-Path $dir 'workbuddy.db'
    if (Test-Path -LiteralPath $dbSrc) {
        if (-not (Test-Path -LiteralPath $edHome)) { New-Item -ItemType Directory -Path $edHome -Force | Out-Null }
        $dbDst = Join-Path $edHome 'workbuddy.db'
        $stage = $null
        try {
            $stage = New-StagedDb $dir
            $stageDb = Join-Path $stage 'workbuddy.db'

            if ($remap) {
                $cur = Get-CurrentAccount $product
                $newUid = ''
                if ($cur) { $newUid = [string]$cur.uid }
                if ($mode -eq 'custom') {
                    # Rewrite by the SELECTED ids, not by the manifest account: the
                    # backup may hold conversations from more than one account, and
                    # Invoke-UidRemap would only touch the manifest's rows - the
                    # others would stay invisible to the logged-in account even
                    # though the user asked to take them over.
                    try {
                        [void](Set-UidForIds $stageDb $validSelected $newUid)
                        $remapDone = $true
                    } catch {
                        $remapReason = 'remap_failed'
                        Write-Log ('remap by id failed: ' + $_.Exception.Message)
                    }
                } else {
                    $old = ''
                    if ($mf.account -and $mf.account.uid) { $old = [string]$mf.account.uid }
                    $chk = Test-RemapSafe $stageDb $old $newUid
                    if ($chk.ok) {
                        try { [void](Invoke-UidRemap $stageDb $old $newUid); $remapDone = $true }
                        catch { $remapReason = 'remap_failed'; Write-Log ('remap failed: ' + $_.Exception.Message) }
                    } else {
                        $remapReason = [string]$chk.reason
                    }
                }
            }

            if ($mode -eq 'full') {
                Remove-Item -LiteralPath ($dbDst + '-wal') -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath ($dbDst + '-shm') -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $stageDb -Destination $dbDst -Force
            } else {
                # merge and custom both merge INTO the destination database, and
                # Open-WbDatabase throws no_database when it does not exist yet.
                # A fresh install (or a never-used edition home) has no db, which
                # is exactly the "new machine" case these modes are for - so seed
                # the destination from the backup db first.
                #
                # Seeding builds a CANDIDATE inside the staging directory and only
                # moves it into place once fully prepared. Installing the backup db
                # first and pruning afterwards would leave a FULL copy (unselected
                # rows included) sitting at the destination if pruning failed - and
                # a destination without a db has nothing to put into the pre-restore
                # backup, so that damage could not be rolled back.
                if (-not (Test-Path -LiteralPath $dbDst)) {
                    $seed = Join-Path $stage 'dest-seed.db'
                    Copy-Item -LiteralPath $stageDb -Destination $seed -Force
                    if ($mode -eq 'custom') {
                        # The seed contains EVERY backup row - including cloud
                        # rows, which Get-RestorePlan intentionally leaves out of
                        # the plan. Build the removal list from the seed's OWN
                        # rows (everything not selected), not from the plan:
                        # otherwise cloud rows would slip through the diff and
                        # get installed. Custom restore installs exactly the
                        # user's selection and nothing else.
                        # Chunked IN deletes - a chunked NOT IN would only test
                        # its own chunk and delete selected ids living in other
                        # chunks.
                        $selIds = @{}
                        foreach ($k in $validSelected.Keys) { $selIds[[string]$k] = $true }
                        $db = $null
                        try {
                            $db = Open-WbDatabasePath $seed
                            [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
                            try {
                                $allIds = @([WbSqlite]::Query($db, 'SELECT id FROM sessions', $null) |
                                            ForEach-Object { [string]$_['id'] })
                                $unselected = @($allIds | Where-Object { -not $selIds.ContainsKey($_) })
                                $chunk = 400
                                for ($i = 0; $i -lt $unselected.Count; $i += $chunk) {
                                    $tail = @($unselected[$i..([Math]::Min($i + $chunk - 1, $unselected.Count - 1))])
                                    $ph = @()
                                    for ($k = 0; $k -lt $tail.Count; $k++) { $ph += ('?{0}' -f ($k + 1)) }
                                    $inList = ($ph -join ', ')
                                    try {
                                        [void][WbSqlite]::Exec($db,
                                            ("DELETE FROM session_usage WHERE session_id IN ({0})" -f $inList), $tail)
                                    } catch { }   # optional table, same as the purge path
                                    [void][WbSqlite]::Exec($db,
                                        ("DELETE FROM sessions WHERE id IN ({0})" -f $inList), $tail)
                                }
                                [void][WbSqlite]::Exec($db, 'COMMIT', $null)
                            } catch { [void][WbSqlite]::Exec($db, 'ROLLBACK', $null); throw }
                        } catch {
                            Remove-Item -LiteralPath $seed -Force -ErrorAction SilentlyContinue
                            throw
                        } finally { if ($null -ne $db) { [WbSqlite]::Close($db) } }
                    }
                    # Candidate ready: install it. If the install itself fails,
                    # remove whatever half-written destination file got created -
                    # never leave a partial database behind.
                    Remove-Item -LiteralPath ($dbDst + '-wal') -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath ($dbDst + '-shm') -Force -ErrorAction SilentlyContinue
                    try {
                        Copy-Item -LiteralPath $seed -Destination $dbDst -Force
                    } catch {
                        Remove-Item -LiteralPath $dbDst -Force -ErrorAction SilentlyContinue
                        throw
                    }
                    Remove-Item -LiteralPath $seed -Force -ErrorAction SilentlyContinue
                    # The seeded rows never pass through Merge-DbSessions (its
                    # INSERT OR IGNORE sees them as already present), so count
                    # them here - otherwise a successful restore into an empty
                    # destination reports zero conversations added.
                    $db = $null
                    try {
                        $db = Open-WbDatabasePath $dbDst
                        $r = [WbSqlite]::Query($db, 'SELECT count(*) AS n FROM sessions', $null)
                        $merged += [int]$r[0]['n']
                    } finally { if ($null -ne $db) { [WbSqlite]::Close($db) } }
                }
                if ($mode -eq 'custom') {
                    # Refresh ONLY the ids the user selected. Merge-DbSessions with
                    # -SelectedIds never inserts unselected backup-only rows and never
                    # deletes local-only rows, so this stays a true custom restore.
                    # Counts were derived from the plan above, not from this call.
                    [void](Merge-DbSessions $product $stageDb -SelectedIds $validSelected)
                } else {
                    # += not =: when the destination db was missing, the seeded rows
                    # were already counted into $merged above; a plain assignment
                    # here would discard that count (the merge itself inserts zero
                    # rows, every backup row is already in place).
                    $merged += (Merge-DbSessions $product $stageDb)
                }
            }
        } catch {
            Remove-StagedDb $stage
            Write-Log ('database restore failed: ' + $_.Exception.Message)
            throw ('db_restore_failed: ' + $_.Exception.Message)
        }
        Remove-StagedDb $stage
    }

    # session files
    $srcProjects = Join-Path $dir 'projects'
    if (Test-Path -LiteralPath $srcProjects) {
        $dstProjects = Join-Path $edHome 'projects'
        if (-not (Test-Path -LiteralPath $dstProjects)) { New-Item -ItemType Directory -Path $dstProjects -Force | Out-Null }
        foreach ($slugDir in @(Get-ChildItem -LiteralPath $srcProjects -Directory -ErrorAction SilentlyContinue)) {
            $dst = Join-Path $dstProjects $slugDir.Name
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            foreach ($f in @(Get-ChildItem -LiteralPath $slugDir.FullName -File -ErrorAction SilentlyContinue)) {
                $target = Join-Path $dst $f.Name
                if ($mode -eq 'merge' -and (Test-Path -LiteralPath $target)) { continue }
                if ($mode -eq 'custom') {
                    # Copy a transcript only when its session id was selected.
                    # No "target exists" exception: an UNSELECTED backup-only
                    # conversation must stay absent locally, so its file is not
                    # copied either. The .file-rollback companion shares the id.
                    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                    $sid = $base
                    if ($base.EndsWith('.file-rollback')) { $sid = $base.Substring(0, $base.Length - '.file-rollback'.Length) }
                    if (-not $validSelected.ContainsKey($sid)) { continue }
                }
                Copy-Item -LiteralPath $f.FullName -Destination $target -Force
                $restored++
            }
            foreach ($sd in @(Get-ChildItem -LiteralPath $slugDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $target = Join-Path $dst $sd.Name
                if ($mode -eq 'merge' -and (Test-Path -LiteralPath $target)) { continue }
                if ($mode -eq 'custom') {
                    # The attachment folder is named after the session id; copy
                    # it only for a selected conversation, same rule as the
                    # transcript loop above.
                    if (-not $validSelected.ContainsKey($sd.Name)) { continue }
                }
                Copy-Tree $sd.FullName $target $sd.Name
            }
        }
    }

    # restore per-account snapshots so titles come back with the sessions
    $srcUsers = Join-Path $dir 'users'
    if (Test-Path -LiteralPath $srcUsers) {
        foreach ($u in @(Get-ChildItem -LiteralPath $srcUsers -Directory -ErrorAction SilentlyContinue)) {
            $snap = Join-Path $u.FullName 'sidebar-list-snapshot.json'
            if (-not (Test-Path -LiteralPath $snap)) { continue }
            $dstU = Join-Path $edHome $u.Name
            if (-not (Test-Path -LiteralPath $dstU)) { New-Item -ItemType Directory -Path $dstU -Force | Out-Null }
            $dstSnap = Join-Path $dstU 'sidebar-list-snapshot.json'
            if ($mode -eq 'merge' -and (Test-Path -LiteralPath $dstSnap)) { continue }
            # A sidebar snapshot is an account-wide rendering cache covering ALL
            # conversations, not one row. In custom mode copying it would change
            # the titles of conversations the user did NOT select, so skip it
            # entirely - the client rebuilds the cache from the database anyway.
            if ($mode -eq 'custom') { continue }
            Copy-Item -LiteralPath $snap -Destination $dstSnap -Force
        }
    }

    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}

    # Deliberately NOT restarting the client here: the page asks the user whether
    # to open it, and only starts it if they say yes.
    Write-Log ("restore done: {0} edition={1} from={2} cross={3} mode={4} files={5} merged={6} remap={7} pushed={8} added={9} kept={10}" -f $name, $product, $sourceEdition, $crossEdition, $mode, $restored, $merged, $remapDone, $customPushed, $customAdded, $customKept)
    return [pscustomobject]@{
        ok            = $true
        mode          = $mode
        edition       = $product
        sourceEdition = $sourceEdition
        crossEdition  = $crossEdition
        home          = $edHome
        files         = $restored
        merged        = $merged
        customPushed  = $customPushed
        customAdded   = $customAdded
        customKept    = $customKept
        sessions      = @($mf.sessions).Count
        remapDone     = $remapDone
        remapReason   = $remapReason
        preBackup     = $(if ($pre) { $pre.name } else { '' })
        restarted     = $false
        clientExe     = ''
        clientWasOpen = $wasRunning
    }
}

# --------------------------------------------------------------------------
# http helpers
# --------------------------------------------------------------------------
function Read-HttpRequest($stream) {
    $buffer = New-Object byte[] 8192
    $ms = New-Object System.IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        $ms.Write($buffer, 0, $n)
        $txt = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        $headerEnd = $txt.IndexOf("`r`n`r`n")
        if ($ms.Length -gt 131072) { break }
    }
    if ($headerEnd -lt 0) { return $null }

    $arr = $ms.ToArray()
    $headText = [Text.Encoding]::ASCII.GetString($arr, 0, $headerEnd)
    $lines = $headText -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $idx = $lines[$i].IndexOf(':')
        if ($idx -gt 0) {
            $headers[$lines[$i].Substring(0, $idx).Trim().ToLower()] = $lines[$i].Substring($idx + 1).Trim()
        }
    }
    $len = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$len) }

    $bodyStart = $headerEnd + 4
    $bm = New-Object System.IO.MemoryStream
    if ($arr.Length -gt $bodyStart) { $bm.Write($arr, $bodyStart, $arr.Length - $bodyStart) }
    while ($bm.Length -lt $len) {
        $want = [Math]::Min($buffer.Length, $len - $bm.Length)
        $n = $stream.Read($buffer, 0, $want)
        if ($n -le 0) { break }
        $bm.Write($buffer, 0, $n)
    }

    return @{
        method  = $parts[0].ToUpper()
        target  = $parts[1]
        headers = $headers
        body    = [Text.Encoding]::UTF8.GetString($bm.ToArray())
    }
}

function Send-Bytes($stream, [int]$code, [string]$contentType, [byte[]]$body) {
    $reasons = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }
    $reason = 'OK'
    if ($reasons.ContainsKey($code)) { $reason = $reasons[$code] }
    $head = "HTTP/1.1 $code $reason`r`n"
    $head += "Content-Type: $contentType`r`n"
    $head += "Content-Length: $($body.Length)`r`n"
    $head += "Cache-Control: no-store, no-cache`r`n"
    $head += "Pragma: no-cache`r`n"
    $head += "Connection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Send-Json($stream, $obj, [int]$code) {
    if (-not $code) { $code = 200 }
    $json = ConvertTo-Json -InputObject $obj -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes $stream $code 'application/json; charset=utf-8' $bytes
}

function Get-ErrMessage($err) {
    if ($err -is [System.Exception]) {
        $m = $err.Message
        if ($err.InnerException) { $m += ' | ' + $err.InnerException.Message }
        return $m
    }
    return [string]$err
}

function Parse-Query([string]$q) {
    $out = @{}
    if (-not $q) { return $out }
    foreach ($pair in $q.Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=')
        $k = [System.Uri]::UnescapeDataString($kv[0])
        $v = ''
        if ($kv.Count -gt 1) { $v = [System.Uri]::UnescapeDataString(($kv[1..($kv.Count - 1)] -join '=')) }
        $out[$k] = $v
    }
    return $out
}

# --------------------------------------------------------------------------
# api
# --------------------------------------------------------------------------
function Invoke-Api([string]$path, $query, $req) {
    $body = $null
    if ($req.body -and $req.body.Trim()) {
        try { $body = $req.body | ConvertFrom-Json } catch { $body = $null }
    }

    switch ($path) {
        '/api/state' {
            $active = Get-ActiveEdition
            $profiles = Get-Profiles
            $backups = Get-Backups

            # one entry per edition, each with its own login state, data root,
            # session stats and client process state
            $editionStates = New-Object System.Collections.Generic.List[object]
            foreach ($p in $Products) {
                $a = Read-AuthInfo $p.Id
                $acct = $null
                if ($a -and $a.uid) {
                    $days = 0
                    if ($a.refreshExpiresAt -gt 0) { $days = [int][Math]::Floor(($a.refreshExpiresAt - (Get-NowMs)) / 86400000.0) }
                    $saved = $false
                    foreach ($pr in $profiles) { if ($pr.product -eq $p.Id -and $pr.uid -eq $a.uid) { $saved = $true } }
                    $acct = [pscustomobject]@{
                        uid            = $a.uid
                        shortUid       = (Get-DisplayName $a.uid)
                        uin            = $a.uin
                        uinMask        = (Mask-Uin $a.uin)
                        nickname       = (Get-Nickname $p.Id $a.uid)
                        product        = $a.product
                        domain         = $a.domain
                        daysLeft       = $days
                        refreshExpires = (ConvertFrom-Ms $a.refreshExpiresAt)
                        accessExpires  = (ConvertFrom-Ms $a.expiresAt)
                        lastRefresh    = (ConvertFrom-Ms $a.lastRefreshTime)
                        saved          = $saved
                    }
                }
                $procs = @(Get-ClientProcesses $p.Proc)
                $exe = (Get-CachedExePath $p.Id)
                if (-not $exe -and $procs.Count -gt 0) {
                    # cheap discovery: the exe path of an already running client
                    foreach ($pr in $procs) {
                        try {
                            if ($pr.Path) { $exe = [string]$pr.Path; Set-CachedExePath $p.Id $exe; break }
                        } catch { }
                    }
                }
                $editionStates.Add([pscustomobject]@{
                    id           = $p.Id
                    domain       = $p.Domain
                    home         = $p.Home
                    homeExists   = (Test-Path -LiteralPath $p.Home)
                    infoPath     = (Get-InfoPath $p.Id)
                    infoExists   = (Test-Path -LiteralPath (Get-InfoPath $p.Id))
                    running      = ($procs.Count -gt 0)
                    processCount = $procs.Count
                    exe          = $exe
                    loggedIn     = ($null -ne $acct)
                    account      = $acct
                    stats        = (Get-SessionStats $p.Id)
                })
            }

            $activeState = $null
            foreach ($e in $editionStates) { if ($e.id -eq $active) { $activeState = $e } }
            $activeAcct = $null
            $activeStats = $null
            if ($activeState) { $activeAcct = $activeState.account; $activeStats = $activeState.stats }

            $running = @(Get-ClientProcesses '*')
            $client = [pscustomobject]@{
                running = ($running.Count -gt 0)
                count   = $running.Count
                names   = (@($running | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ',')
                exe     = (Get-CachedExePath $active)
            }
            return [pscustomobject]@{
                ok            = $true
                version       = $AppVersion
                activeEdition = $active
                editions      = $editionStates.ToArray()
                account       = $activeAcct
                profiles      = $profiles
                backups       = $backups
                stats         = $activeStats
                client        = $client
                paths         = [pscustomobject]@{
                    workbuddyHome   = (Get-EditionHome $active)
                    workbuddyHomeCn = $WbHome
                    workbuddyHomeAi = $WbHomeAi
                    authDir         = $AuthDir
                    profiles        = $ProfilesDir
                    backups         = $BackupsDir
                }
            }
        }

        '/api/sessions' {
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $all = Get-SessionsIndex $edition
            # Same rule as the stats card above: this list is "local
            # conversations", so cloud rows stay out of it. They are reachable
            # through "all conversations -> cloud".
            $all = @($all | Where-Object { [string]$_.transport -eq 'local' })
            $limit = 300
            if ($query.ContainsKey('limit')) { [void][int]::TryParse($query['limit'], [ref]$limit) }
            $items = @($all | Select-Object -First $limit)
            return [pscustomobject]@{
                ok       = $true
                edition  = $edition
                total    = $all.Count
                sessions = $items
            }
        }

        '/api/sessions/all' {
            # The "all conversations" window: every row in the database, deleted
            # ones included, plus one tally per account so the first filter row can
            # be built without a second round trip.
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            # refresh=1 comes from the explicit refresh button. Get-SessionsIndex
            # serves a 10-second cache, so without this two quick clicks would show
            # the same stale list and the button would look broken.
            if ($query.ContainsKey('refresh') -and [string]$query['refresh'] -eq '1') {
                $script:SessionCache = @{}
                $script:SessionCacheAt = @{}
            }
            # Get-SessionsIndex returns a real array; wrapping it with @() here
            # would nest it one level deeper and break every member access
            $all = Get-SessionsIndex $edition -IncludeDeleted
            $cur = Get-CurrentAccount $edition
            $curUid = ''
            if ($cur) { $curUid = [string]$cur.uid }

            $items = New-Object System.Collections.Generic.List[object]
            $accMap = @{}
            $accOrder = New-Object System.Collections.Generic.List[string]
            foreach ($s in $all) {
                $u = [string]$s.uid
                $state = 'visible'
                # Cloud rows carry deleted_at = -1, which is a marker, not a
                # deletion, so they used to fall through to "visible". They are
                # their own bucket now: they cannot be edited here at all, and
                # lumping them in with the local, editable rows was misleading.
                if ($s.deleted) { $state = 'deleted' }
                elseif ($s.archived) { $state = 'archived' }
                elseif ([string]$s.transport -ne 'local') { $state = 'cloud' }
                $mine = ($curUid -ne '' -and $u -eq $curUid)
                $items.Add([pscustomobject]@{
                    id        = [string]$s.id
                    title     = [string]$s.title
                    slug      = [string]$s.slug
                    space     = [string]$s.space
                    uid       = $u
                    shortUid  = (Get-DisplayName $u)
                    nickname  = (Get-Nickname $edition $u)
                    bytes     = [long]$s.bytes
                    updatedMs = [long]$s.updatedMs
                    transport = [string]$s.transport
                    state     = $state
                    archived  = [bool]$s.archived
                    deleted   = [bool]$s.deleted
                    mine      = $mine
                    cloud     = ($s.transport -ne 'local')
                })
                if (-not $accMap.ContainsKey($u)) {
                    $accMap[$u] = [pscustomobject]@{
                        uid      = $u
                        nickname = (Get-Nickname $edition $u)
                        shortUid = (Get-DisplayName $u)
                        mine     = $mine
                        total    = 0
                        visible  = 0
                        archived = 0
                        deleted  = 0
                        cloud    = 0
                    }
                    $accOrder.Add($u)
                }
                $a = $accMap[$u]
                $a.total = $a.total + 1
                if ($state -eq 'deleted') { $a.deleted = $a.deleted + 1 }
                elseif ($state -eq 'archived') { $a.archived = $a.archived + 1 }
                elseif ($state -eq 'cloud') { $a.cloud = $a.cloud + 1 }
                else { $a.visible = $a.visible + 1 }
            }
            $accounts = New-Object System.Collections.Generic.List[object]
            foreach ($k in $accOrder) { $accounts.Add($accMap[$k]) }
            $sortedAcc = @($accounts | Sort-Object -Property @{ Expression = { if ($_.uid -eq '') { 2 } elseif ($_.mine) { 0 } else { 1 } } }, @{ Expression = { $_.total }; Descending = $true })

            return [pscustomobject]@{
                ok       = $true
                edition  = $edition
                running  = ((Get-ClientProcesses (Get-ProductProc $edition)).Count -gt 0)
                total    = $items.Count
                current  = [pscustomobject]@{
                    uid      = $curUid
                    nickname = $(if ($curUid) { Get-Nickname $edition $curUid } else { '' })
                    uinMask  = $(if ($cur) { Mask-Uin ([string]$cur.uin) } else { '' })
                }
                accounts = $sortedAcc
                sessions = $items.ToArray()
            }
        }

        '/api/sessions/fork' {
            $edition = ''
            $sid = ''
            if ($body) {
                if ($body.edition) { $edition = [string]$body.edition }
                if ($body.id) { $sid = [string]$body.id }
            }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $r = Fork-Session $edition $sid
            return [pscustomobject]@{ ok = $true; edition = $edition; id = $r.id; title = $r.title }
        }

        '/api/sessions/state' {
            $edition = ''
            $sid = ''
            $target = ''
            if ($body) {
                if ($body.edition) { $edition = [string]$body.edition }
                if ($body.id) { $sid = [string]$body.id }
                if ($body.state) { $target = [string]$body.state }
            }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $state = Set-SessionState $edition $sid $target
            return [pscustomobject]@{ ok = $true; edition = $edition; id = $sid; state = $state }
        }

        '/api/purge/list' {
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $r = Get-DeletedSessions $edition
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($s in $r.sessions) {
                $items.Add([pscustomobject]@{
                    id        = $s.id
                    title     = $s.title
                    uid       = $s.uid
                    shortUid  = (Get-DisplayName $s.uid)
                    nickname  = (Get-Nickname $edition $s.uid)
                    bytes     = $s.bytes
                    updatedMs = $s.updatedMs
                    archived  = $s.archived
                    mine      = $s.mine
                    defaultOn = $true
                })
            }
            $curUid = ''
            $curUin = ''
            if ($r.account) {
                $curUid = [string]$r.account.uid
                $curUin = Mask-Uin ([string]$r.account.uin)
            }
            return [pscustomobject]@{
                ok       = $true
                edition  = $edition
                total    = $items.Count
                running  = ((Get-ClientProcesses (Get-ProductProc $edition)).Count -gt 0)
                account  = [pscustomobject]@{
                    uid      = $curUid
                    uinMask  = $curUin
                    nickname = $(if ($curUid) { Get-Nickname $edition $curUid } else { '' })
                }
                sessions = $items.ToArray()
            }
        }

        '/api/purge/apply' {
            $edition = ''
            $ids = @()
            $doBackup = $true
            if ($body) {
                if ($body.edition) { $edition = [string]$body.edition }
                if ($body.ids) { $ids = @($body.ids) }
                if ($null -ne $body.backup) { $doBackup = [bool]$body.backup }
            }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            if ($ids.Count -eq 0) { throw 'nothing_to_purge' }
            return (Invoke-PurgeSessions $edition $ids $doBackup)
        }

        '/api/backup/create' {
            $inc = $true
            if ($null -ne $body -and $null -ne $body.includeAttachments) { $inc = [bool]$body.includeAttachments }
            $edition = ''
            if ($body -and $body.edition) { $edition = [string]$body.edition }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $meta = New-Backup $inc '' '' $edition
            return [pscustomobject]@{ ok = $true; backup = $meta }
        }

        '/api/backup/restore-plan' {
            # Read-only FULL list of the backup's own conversations (cloud rows
            # excluded). The dialog shows every one of them and lets the user pick,
            # per conversation, whether to use the backup copy. No truncation here
            # and nothing is written. Restore-Backup mode='custom' recomputes the
            # same plan with the same edition before applying the user's id set.
            $name = ''
            if ($body) { $name = [string]$body.name }
            $target = ''
            if ($body -and $body.target) { $target = [string]$body.target }
            if (-not $name) { throw 'name_required' }
            $dir = Join-Path $BackupsDir $name
            if (-not (Test-Path -LiteralPath $dir)) { throw 'backup_missing' }
            $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
            $ed = $target
            if (-not (Test-Edition $ed)) {
                if ($mf -and $mf.edition) { $ed = [string]$mf.edition }
                if (-not (Test-Edition $ed)) { $ed = Get-ActiveEdition }
            }
            $plan = Get-RestorePlan $name $ed
            return [pscustomobject]@{
                ok                   = $true
                edition              = $ed
                total                = $plan.total
                hasBackupDb          = $plan.hasBackupDb
                backupHasAttachments = $plan.backupHasAttachments
                cloudSkipped         = $plan.cloudSkipped
                groups               = $plan.groups
                items                = $plan.items
            }
        }

        '/api/backup/restore' {
            $name = ''
            if ($body) { $name = [string]$body.name }
            $mode = 'full'
            if ($body -and $body.mode) { $mode = [string]$body.mode }
            # 'sync' (time-based, backend-decided) was removed; custom restore
            # replaces it. full and merge are unchanged.
            if ($mode -notin @('full', 'merge', 'custom')) { throw 'bad_mode' }
            $remap = $false
            if ($body -and $null -ne $body.remap) { $remap = [bool]$body.remap }
            $target = ''
            if ($body -and $body.target) { $target = [string]$body.target }

            # mode='custom' carries the explicit set of ids the user chose to
            # overwrite with the backup. Validate at the boundary: it must be a
            # real JSON array of non-empty strings, capped to prevent abuse. Ids
            # that do not exist in the backup are silently ignored downstream
            # (Restore-Backup intersects them with the restore plan).
            $customIds = @{}
            if ($mode -eq 'custom') {
                if ($null -eq $body -or $null -eq $body.PSObject.Properties['selectedIds']) { throw 'selected_ids_required' }
                $raw = $body.selectedIds
                if ($null -eq $raw -or $raw -is [string]) { throw 'selected_ids_must_be_array' }
                $arr = @($raw)
                if ($arr.Count -gt 5000) { throw 'too_many_selected' }
                foreach ($x in $arr) {
                    if ($x -isnot [string]) { throw 'selected_ids_must_be_array' }
                    $s = [string]$x
                    if (-not $s.Trim()) { throw 'selected_ids_invalid' }
                    $customIds[$s] = $true
                }
            }
            $r = Restore-Backup $name $mode $remap $target $customIds
            return $r
        }

        '/api/backup/delete' {
            $name = ''
            if ($body) { $name = [string]$body.name }
            if (-not $name) { throw 'name_required' }
            # The name must be ONE leaf folder name. Without this, "." resolves to
            # $BackupsDir itself and "..\backups2" resolves to a sibling that still
            # starts with the backups path - both passed the old containment check
            # below, and the first one would Remove-Item -Recurse every backup.
            if ($name -ne [IO.Path]::GetFileName($name) -or $name -eq '.' -or $name -eq '..') {
                throw 'invalid_path'
            }
            if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'invalid_path' }
            $dir = Join-Path $BackupsDir $name
            if (-not (Test-Path -LiteralPath $dir)) { throw 'backup_missing' }
            $full = [IO.Path]::GetFullPath($dir)
            # Strictly INSIDE the backups root: the trailing separator is what
            # stops a sibling like "backups2" from matching, and the comparison
            # must be case-insensitive on Windows.
            $rootFull = [IO.Path]::GetFullPath($BackupsDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid_path' }
            $delErr = $null
            try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop } catch { $delErr = $_ }
            if (Test-Path -LiteralPath $full) { throw ('delete_failed: ' + (Get-ErrMessage $delErr)) }
            Write-Log ('backup deleted: ' + $name)
            return [pscustomobject]@{ ok = $true }
        }

        '/api/backup/detail' {
            $name = ''
            if ($query.ContainsKey('name')) { $name = $query['name'] }
            if (-not $name) { throw 'name_required' }
            $meta = Get-BackupMeta $name
            if (-not $meta) { throw 'backup_missing' }
            $sessions = Get-BackupSessions $name ([string]$meta.edition)
            $dir = Join-Path $BackupsDir $name
            $hasDb = Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db')
            $dbInfo = [pscustomobject]@{
                hasDatabase = $hasDb
                hasWal      = (Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db-wal'))
            }
            # Everything the backup's database holds, deleted and cloud rows
            # included. The staged database is opened once for both the tallies
            # and the row list.
            $detail = [pscustomobject]@{
                counts   = [pscustomobject]@{ total = 0; archived = 0; deleted = 0; cloud = 0; alive = 0 }
                sessions = @()
            }
            if ($hasDb) {
                try { $detail = Get-BackupDbDetail $name ([string]$meta.edition) }
                catch { Write-Log ('backup detail failed: ' + $_.Exception.Message) }
            }
            # The account that is logged in right now, for the edition this
            # backup belongs to. The viewer uses it for exactly one thing: the
            # ownership column highlights that account and nothing else. The
            # account the backup was taken under is no longer singled out - it
            # is just another row in the filter now.
            $bkEdition = [string]$meta.edition
            $cur = $null
            if ($bkEdition) { $cur = Get-CurrentAccount $bkEdition }
            $curUid = ''
            $curNick = ''
            $curUin = ''
            if ($cur) {
                $curUid = [string]$cur.uid
                $curNick = Get-Nickname $bkEdition $curUid
                $curUin = Mask-Uin ([string]$cur.uin)
            }
            return [pscustomobject]@{
                ok         = $true
                backup     = $meta
                edition    = $bkEdition
                sessions   = $sessions
                dbSessions = $detail.sessions
                hasDbList  = ($detail.sessions.Count -gt 0)
                database   = $dbInfo
                counts     = $detail.counts
                current    = [pscustomobject]@{
                    uid      = $curUid
                    nickname = $curNick
                    uinMask  = $curUin
                }
            }
        }

        '/api/backup/remap-check' {
            $name = ''
            if ($query.ContainsKey('name')) { $name = $query['name'] }
            $dir = Join-Path $BackupsDir $name
            $mf = Read-JsonFile (Join-Path $dir 'manifest.json')
            if (-not $mf) { throw 'manifest_missing' }
            $hasWal = (Test-Path -LiteralPath (Join-Path $dir 'workbuddy.db-wal'))
            # the "current" account for a remap is the current account of the edition
            # the backup is being restored INTO, not of whichever client is in front
            $sourceEdition = ''
            if ($mf.edition) { $sourceEdition = [string]$mf.edition }
            elseif ($mf.account -and $mf.account.product) { $sourceEdition = [string]$mf.account.product }
            if (-not (Test-Edition $sourceEdition)) { $sourceEdition = Get-ActiveEdition }
            $edition = $sourceEdition
            if ($query.ContainsKey('target')) {
                $want = $query['target']
                if (Test-Edition $want) { $edition = $want }
            }
            $cur = Get-CurrentAccount $edition
            $old = ''
            if ($mf.account -and $mf.account.uid) { $old = [string]$mf.account.uid }
            # check against a staged copy: opening the backup in place would make
            # SQLite replay its log and touch the backup itself
            $chk = @{ ok = $false; reason = 'no_database'; oldCount = 0; newCount = 0 }
            $stage = $null
            try {
                $stage = New-StagedDb $dir
                $chk = Test-RemapSafe (Join-Path $stage 'workbuddy.db') $old ($(if ($cur) { $cur.uid } else { '' }))
            } catch {
                $chk = @{ ok = $false; reason = 'db_unreadable'; oldCount = 0; newCount = 0 }
            } finally {
                Remove-StagedDb $stage
            }
            $newMask = ''
            if ($cur) { $newMask = (Mask-Uin $cur.uin) }
            $newNick = ''
            if ($cur) { $newNick = (Get-Nickname $edition $cur.uid) }
            return [pscustomobject]@{
                ok            = $true
                edition       = $edition
                sourceEdition = $sourceEdition
                crossEdition  = ($edition -ne $sourceEdition)
                allowed       = [bool]$chk.ok
                reason        = [string]$chk.reason
                oldUid        = $old
                newUid        = $(if ($cur) { $cur.uid } else { '' })
                current       = $newMask
                currentNick   = $newNick
                oldCount      = [int]$chk.oldCount
                newCount      = [int]$chk.newCount
                hasWal        = $hasWal
            }
        }

        '/api/accounts/save' {
            $saved = New-Object System.Collections.Generic.List[object]
            $want = ''
            if ($body -and $body.edition) { $want = [string]$body.edition }
            foreach ($p in $Products) {
                if ($want -and $p.Id -ne $want) { continue }
                try {
                    $m = Save-Profile $p.Id
                    if ($m) { $saved.Add($m) }
                } catch { }
            }
            if ($saved.Count -eq 0) { throw 'no_login_state' }
            return [pscustomobject]@{ ok = $true; saved = $saved.ToArray() }
        }

        '/api/accounts/switch' {
            $product = ''
            $uid = ''
            $restart = $true
            $move = $false
            if ($body) {
                $product = [string]$body.product
                $uid = [string]$body.uid
                if ($null -ne $body.restart) { $restart = [bool]$body.restart }
                if ($null -ne $body.moveSessions) { $move = [bool]$body.moveSessions }
            }
            if (-not $product -or -not $uid) { throw 'params_required' }
            if (-not (Test-Edition $product)) { throw 'unknown_edition' }
            $r = Switch-Account $product $uid $restart $move
            return $r
        }

        '/api/accounts/logout' {
            $product = ''
            $restart = $true
            if ($body) {
                if ($body.product) { $product = [string]$body.product }
                if ($null -ne $body.restart) { $restart = [bool]$body.restart }
            }
            if (-not $product) { $product = Get-ActiveEdition }
            if (-not (Test-Edition $product)) { throw 'unknown_edition' }
            $r = Clear-Login $product $restart
            return $r
        }

        '/api/accounts/nickname' {
            $product = ''
            $uid = ''
            $nick = ''
            if ($body) {
                $product = [string]$body.product
                $uid = [string]$body.uid
                $nick = [string]$body.nickname
            }
            if (-not $product -or -not $uid) { throw 'params_required' }
            $v = Set-Nickname $product $uid $nick
            return [pscustomobject]@{ ok = $true; product = $product; uid = $uid; nickname = $v }
        }

        '/api/models/groups' {
            # The tab bar: every models.json* file in the edition home, with the
            # title stored inside each one.
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $g = Get-ModelGroups $edition
            return [pscustomobject]@{ ok = $true; edition = $edition; groups = @($g) }
        }

        '/api/models/group-switch' {
            $edition = ''
            $file = ''
            if ($body) {
                $edition = [string]$body.edition
                $file = [string]$body.file
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            $moved = Switch-ModelGroup $edition $file
            $g = Get-ModelGroups $edition
            return [pscustomobject]@{ ok = $true; edition = $edition; moved = $moved; groups = @($g) }
        }

        '/api/models/group-new' {
            $edition = ''
            if ($body) { $edition = [string]$body.edition }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            $made = New-ModelGroup $edition
            $g = Get-ModelGroups $edition
            return [pscustomobject]@{ ok = $true; edition = $edition; made = $made; groups = @($g) }
        }

        '/api/models/group-title' {
            $edition = ''
            $file = ''
            $title = ''
            if ($body) {
                $edition = [string]$body.edition
                $file = [string]$body.file
                $title = [string]$body.title
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            $ren = Set-ModelGroupTitle $edition $file $title
            $g = Get-ModelGroups $edition
            return [pscustomobject]@{ ok = $true; edition = $edition; renamed = $ren; groups = @($g) }
        }

        '/api/models/group-delete' {
            # Delete ONE parked group file. The active models.json is refused:
            # it is the file the client reads, and removing it would leave the
            # client with no custom models at all - "switch to another group,
            # then delete this one" is the safe order and the UI simply does not
            # offer delete on the active tab.
            $edition = ''
            $file = ''
            if ($body) {
                $edition = [string]$body.edition
                $file = [string]$body.file
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if (-not $file) { throw 'group_required' }
            if ($file -eq 'models.json') { throw 'group_is_active' }
            if ($file -ne [IO.Path]::GetFileName($file)) { throw 'bad_group_name' }
            if (-not (Test-GroupFile $file)) { throw 'bad_group_name' }
            $dir = Get-EditionHome $edition
            $p = Join-Path $dir $file
            if (-not (Test-Path -LiteralPath $p)) { throw 'group_not_found' }
            # Same containment rule as the backup delete: the resolved path has
            # to sit strictly inside the edition home, so a crafted name cannot
            # reach a sibling or a parent directory.
            $full = [IO.Path]::GetFullPath($p)
            $rootFull = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid_path' }
            $delErr = $null
            try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop } catch { $delErr = $_ }
            if (Test-Path -LiteralPath $full) { throw ('delete_failed: ' + (Get-ErrMessage $delErr)) }
            Write-Log ("models group delete: {0} {1}" -f $edition, $file)
            $g = Get-ModelGroups $edition
            return [pscustomobject]@{ ok = $true; edition = $edition; deleted = $file; groups = @($g) }
        }

        '/api/models/group-test' {
            # "Test" on a model-file tab. Probes the models in ONE models file,
            # each against its own url / key (see Test-ModelGroupChat - this is
            # NOT the batch-import probe, which shares a single endpoint).
            #
            # $body.file selects the file and defaults to the active
            # models.json; a parked group works too, since the user may want to
            # check a set of models before switching to it.
            $edition = ''
            $file = ''
            $ids = @()
            $concurrency = 8
            if ($body) {
                $edition = [string]$body.edition
                $file = [string]$body.file
                $ids = $body.ids
                if ($null -ne $body.PSObject.Properties['concurrency']) { $concurrency = [int]$body.concurrency }
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if (-not $file) { $file = 'models.json' }
            if ($file -ne [IO.Path]::GetFileName($file)) { throw 'bad_group_name' }
            if (-not (Test-GroupFile $file)) { throw 'bad_group_name' }
            $r = Test-ModelGroupChat $edition $file $ids $concurrency
            if (-not $r.ok) { throw $r.error }
            return [pscustomobject]@{ ok = $true; file = $file; total = $r.total; results = $r.results }
        }

        '/api/models/repair' {
            # Bring an existing file in line with the client's own rule: one
            # visible entry per id. Earlier same-id twins are hidden (renamed to
            # "-id"), never deleted. Used by the model page on load, so a file
            # that already had clashes is fixed the moment it is opened.
            $edition = ''
            if ($body) { $edition = [string]$body.edition }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            $r = Repair-ModelDuplicates $edition
            Write-Log ("models repair: {0} changed={1} hid={2}" -f $edition, $r.changed, (@($r.hidden)).Count)
            return $r
        }

        '/api/models/list' {
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $r = Get-ModelsList $edition
            return [pscustomobject]@{
                ok      = $true
                edition = $edition
                path    = $r.path
                exists  = $r.exists
                loadable = $r.ok
                code    = $(if ($r.ok) { '' } else { $r.code })
                count   = $r.count
                models  = $r.models
            }
        }

        '/api/models/batch-list' {
            # Batch import, step 1: the user gave only an endpoint and a key, so
            # work out the listing address from them. Like the "pick a model"
            # dialog this walks the SAME candidate list (Get-ModelProbeUrlCandidates);
            # it just keeps going until one answers instead of stopping at the
            # first, because here the user pasted a bare origin and expects the
            # tool to work the rest out. Which ones were tried, and which
            # answered, are both reported.
            #
            # There is no useCustomProtocol switch on this dialog, so none is
            # read here: that flag governs the CHAT address only.
            $url = ''
            $apiKey = ''
            if ($body) {
                $url = [string]$body.url
                $apiKey = [string]$body.apiKey
            }
            if (-not $url.Trim()) { throw 'url_required' }
            if (-not $apiKey) { throw 'key_required' }
            $r = Get-ModelListWithFallback $url $apiKey $false
            Write-Log ("models batch-list: ok={0} used={1} tried={2} count={3}" -f `
                       $r.ok, $r.usedUrl, $r.tried.Count, $r.models.Count)
            # Say up-front whether model.csv exists, so the dialog can tell the
            # user where the gaps will be filled from before they save.
            $csv = Import-ModelCsv
            return [pscustomobject]@{
                ok      = $r.ok
                status  = $r.status
                code    = $r.code
                message = $r.message
                usedUrl = $r.usedUrl
                tried   = $r.tried
                count   = $r.models.Count
                models  = $r.models
                csvOk   = $csv.ok
                csvPath = $csv.path
                csvRows = @($csv.rows).Count
            }
        }

        '/api/models/batch-test' {
            # Batch import, step 2: probe a list of ids with the same minimal
            # chat request, several at a time.
            $url = ''
            $apiKey = ''
            $ids = @()
            $useCustom = $false
            $concurrency = 4
            if ($body) {
                $url = [string]$body.url
                $apiKey = [string]$body.apiKey
                $ids = $body.ids
                if ($null -ne $body.PSObject.Properties['useCustomProtocol']) { $useCustom = [bool]$body.useCustomProtocol }
                if ($null -ne $body.PSObject.Properties['concurrency']) { $concurrency = [int]$body.concurrency }
            }
            if (-not $url.Trim()) { throw 'url_required' }
            if (-not $apiKey) { throw 'key_required' }
            $r = Test-ModelBatch $url $apiKey $ids $useCustom $concurrency
            if (-not $r.ok) { throw $r.error }
            $okCount = 0
            foreach ($x in $r.results) { if ($x.ok) { $okCount++ } }
            Write-Log ("models batch-test: total={0} ok={1} chatUrl={2}" -f $r.results.Count, $okCount, $r.chatUrl)
            return [pscustomobject]@{
                ok      = $true
                chatUrl = $r.chatUrl
                triedChat = $r.triedChat
                total   = $r.results.Count
                okCount = $okCount
                results = $r.results
            }
        }

        '/api/models/batch-save' {
            # Batch import, step 3: build one full entry per selected id, all
            # sharing the same url / apiKey, with the note the user typed as name.
            $edition = ''
            $url = ''
            $apiKey = ''
            $items = @()
            $icon = ''
            if ($body) {
                $edition = [string]$body.edition
                $url = [string]$body.url
                $apiKey = [string]$body.apiKey
                $items = $body.items
                $icon = [string]$body.icon
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if (-not $url.Trim()) { throw 'url_required' }
            if (-not $apiKey) { throw 'key_required' }

            # Capability values come from three places, in this order:
            #   1. what the listing reported (it knows the real model)
            #   2. model.csv, matched by id - exact first, then wildcard
            #   3. built-in defaults
            # The CSV is read once for the whole batch, not once per model.
            $csv = Import-ModelCsv
            $csvRows = @($csv.rows)
            $mbDefaults = Get-ModelCsvDefaults

            $added = New-Object System.Collections.Generic.List[string]
            $skipped = New-Object System.Collections.Generic.List[object]
            $hidSiblings = New-Object System.Collections.Generic.List[string]
            # One snapshot for the whole batch, taken before anything is written.
            # Letting Save-ModelEntry snapshot per item is what destroyed the way
            # back: it keeps only the newest 20 files, so importing more than 20
            # models pushed the pre-import snapshot out and left nothing but
            # intermediate states of this same batch. Taken here, the "before"
            # state is the oldest of the batch and survives.
            $preImportRaw = Get-ModelsRaw $edition
            if ($preImportRaw.valid) { Save-ModelsSnapshot $edition $preImportRaw.text }
            foreach ($it in (To-ItemArray $items)) {
                if ($null -eq $it) { continue }
                $mid = ([string](Get-ModelProp $it 'id')).Trim()
                if (-not $mid) { continue }
                $nm = [string](Get-ModelProp $it 'name')
                $patch = [pscustomobject]@{
                    id               = $mid
                    name             = $nm
                    url              = $url.Trim()
                    apiKey           = $apiKey
                    useCustomProtocol = $false
                }

                # ---- capabilities: listing > csv > defaults ----
                $row = $null
                if ($csvRows.Count -gt 0) { $row = Find-ModelCsvRow $csvRows $mid }

                # supportsToolCall: the listing has no field for it, so it is
                # csv-then-default.
                $tool = $mbDefaults.supportsToolCall
                if ($row -and $row.ContainsKey('Tool')) { $tool = ConvertTo-CsvBool $row['Tool'] $tool }
                $patch | Add-Member -NotePropertyName supportsToolCall -NotePropertyValue $tool -Force

                # supportsImages: listing wins when it spoke (input_modalities).
                $imgSet = $false
                $img = $mbDefaults.supportsImages
                $pv = Get-ModelProp $it 'supportsImages'
                if ($null -ne $pv) { $img = [bool]$pv; $imgSet = $true }
                $sv = Get-ModelProp $it 'supportsImagesSet'
                if ($null -ne $sv -and [bool]$sv) { $imgSet = $true }
                if (-not $imgSet -and $row -and $row.ContainsKey('Images')) {
                    $img = ConvertTo-CsvBool $row['Images'] $img
                }
                $patch | Add-Member -NotePropertyName supportsImages -NotePropertyValue $img -Force

                # supportsReasoning / efforts: listing wins when it listed levels.
                $efforts = @($mbDefaults.supportedEfforts)
                $defEff = $mbDefaults.defaultEffort
                $reason = $mbDefaults.supportsReasoning
                $lv = Get-ModelProp $it 'supportedEfforts'
                $fromListing = $false
                if ($null -ne $lv) {
                    $got = @()
                    foreach ($e in (To-ItemArray $lv)) {
                        $s = ([string]$e).Trim()
                        if ($s) { $got += $s }
                    }
                    if ($got.Count -gt 0) { $efforts = $got; $reason = $true; $fromListing = $true }
                }
                if (-not $fromListing -and $row) {
                    if ($row.ContainsKey('Think')) { $reason = ConvertTo-CsvBool $row['Think'] $reason }
                    if ($row.ContainsKey('Effort')) {
                        $ce = @(ConvertTo-CsvEfforts $row['Effort'])
                        if ($ce.Count -gt 0) { $efforts = $ce }
                    }
                }
                $dv = Get-ModelProp $it 'defaultEffort'
                if ($null -ne $dv -and ([string]$dv).Trim()) { $defEff = ([string]$dv).Trim() }
                elseif ($row -and $row.ContainsKey('Default')) {
                    $one = ConvertTo-CsvEffortOne $row['Default']
                    if ($one) { $defEff = $one }
                }
                # An effort list the user disabled entirely means "no reasoning".
                if (-not $reason) { $efforts = @(); $defEff = '' }
                # The default must be one of the supported levels or the client
                # would show a default it cannot select.
                if ($defEff -and (@($efforts) -notcontains $defEff)) {
                    if (@($efforts).Count -gt 0) { $defEff = [string]@($efforts)[0] } else { $defEff = '' }
                }
                $patch | Add-Member -NotePropertyName supportsReasoning -NotePropertyValue $reason -Force
                $patch | Add-Member -NotePropertyName supportedEfforts -NotePropertyValue @($efforts) -Force
                $patch | Add-Member -NotePropertyName defaultEffort -NotePropertyValue $defEff -Force

                # ---- token limits: listing > csv, and 0 means "do not write" ----
                # Both halves fall back to csv now. The output cap used to be
                # listing-only, so a gateway that reported no output limit left
                # the field unset with no way to supply it - the context column
                # carried the input length and nothing carried the output one.
                $inTok = 0
                $iv = Get-ModelProp $it 'maxInputTokens'
                if ($null -ne $iv) { try { $inTok = [long]$iv } catch { $inTok = 0 } }
                if ($inTok -le 0 -and $row -and $row.ContainsKey('Ctx')) {
                    $inTok = ConvertTo-CsvTokens $row['Ctx']
                }
                $outTok = 0
                $ov = Get-ModelProp $it 'maxOutputTokens'
                if ($null -ne $ov) { try { $outTok = [long]$ov } catch { $outTok = 0 } }
                if ($outTok -le 0 -and $row -and $row.ContainsKey('Out')) {
                    $outTok = ConvertTo-CsvTokens $row['Out']
                }
                if ($inTok -gt 0) { $patch | Add-Member -NotePropertyName maxInputTokens -NotePropertyValue $inTok -Force }
                if ($outTok -gt 0) { $patch | Add-Member -NotePropertyName maxOutputTokens -NotePropertyValue $outTok -Force }

                # ---- hidden ----
                $hid = $mbDefaults.hidden
                if ($row -and $row.ContainsKey('Hidden')) { $hid = ConvertTo-CsvBool $row['Hidden'] $hid }
                if ($hid) { $patch | Add-Member -NotePropertyName hidden -NotePropertyValue $true -Force }

                # Each id carries its own vendor so the icon the importer drew
                # next to the name is the one that survives into the file. A
                # single shared icon would stamp the same logo on every model,
                # which is exactly what the batch list no longer does.
                #
                # Order:
                #   1. what the UI computed for this row (it already applied the
                #      listing's own value and its icon rules)
                #   2. the explicit model.csv "icon" column - the user's own
                #      override, which is why it beats the name-derived guess
                #   3. a guess derived from the name / id
                #   4. the legacy single-value icon field
                #
                # The csv column sits ABOVE the guess on purpose: someone who
                # bothered to write "GLM API" next to a model whose name gives
                # nothing away means it, and the guess is exactly the thing they
                # were working around.
                $vendor = [string](Get-ModelProp $it 'vendor')
                $fromCsvIcon = ''
                if ($row -and $row.ContainsKey('Icon')) { $fromCsvIcon = ([string]$row['Icon']).Trim() }
                if (-not $vendor -or $vendor -eq 'Custom') {
                    if ($fromCsvIcon) { $vendor = $fromCsvIcon }
                    elseif (-not $vendor) { $vendor = Get-ModelVendorHint $mid $nm }
                }
                if ((-not $vendor -or $vendor -eq 'Custom') -and $icon) { $vendor = $icon }
                if ($vendor) { $patch | Add-Member -NotePropertyName vendor -NotePropertyValue $vendor -Force }
                try {
                    # create=$true always: importing an id that already exists adds
                    # a new entry and hides the old one (see Save-ModelEntry), it
                    # does not overwrite and does not get skipped.
                    $rr = Save-ModelEntry $edition $mid $patch $true -1 $true
                    $added.Add($mid)
                    foreach ($h in (To-ItemArray $rr.hiddenSiblings)) { $hidSiblings.Add([string]$h) }
                } catch {
                    $skipped.Add([pscustomobject]@{ id = $mid; reason = $_.Exception.Message })
                }
            }
            Write-Log ("models batch-save: added={0} skipped={1} hidSiblings={2}" -f `
                       $added.Count, $skipped.Count, $hidSiblings.Count)
            $after = Get-ModelsList $edition
            return [pscustomobject]@{
                ok             = $true
                added          = $added.ToArray()
                skipped        = $skipped.ToArray()
                hiddenSiblings = $hidSiblings.ToArray()
                count          = $after.count
                models         = $after.models
            }
        }

        '/api/models/save' {
            $edition = ''
            $originalId = ''
            $patch = $null
            $create = $false
            $hint = -1
            if ($body) {
                $edition = [string]$body.edition
                $originalId = [string]$body.originalId
                $patch = $body.model
                if ($null -ne $body.PSObject.Properties['create']) { $create = [bool]$body.create }
                # The card's array position, so a hidden duplicate can be acted
                # on without the visible twin swallowing it.
                if ($null -ne $body.PSObject.Properties['index']) { $hint = [int]$body.index }
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if ($null -eq $patch) { throw 'params_required' }
            if ($create) { $originalId = '' }
            elseif (-not $originalId) { throw 'params_required' }
            return (Save-ModelEntry $edition $originalId $patch $create $hint)
        }

        '/api/models/delete' {
            $edition = ''
            $id = ''
            $hint = -1
            if ($body) {
                $edition = [string]$body.edition
                $id = [string]$body.id
                # Same reason as /api/models/save: the position tells the two
                # same-id entries apart.
                if ($null -ne $body.PSObject.Properties['index']) { $hint = [int]$body.index }
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if (-not $id) { throw 'params_required' }
            return (Remove-ModelEntry $edition $id $hint)
        }

        '/api/models/test-chat' {
            # The editor's "test chat" button. Only the return code and one
            # minimal conversation are checked - no model listing first. When
            # the address has to be completed (/chat/completions or
            # /v1/chat/completions) and the completed one works, the working
            # address comes back as fixedUrl so the form can correct itself.
            $edition = ''
            $originalId = ''
            $patch = $null
            $idxHint = -1
            if ($body) {
                $edition = [string]$body.edition
                $originalId = [string]$body.originalId
                $patch = $body.model
                if ($null -ne $body.PSObject.Properties['index'] -and $null -ne $body.index) {
                    try { $idxHint = [int]$body.index } catch { $idxHint = -1 }
                }
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if ($null -eq $patch) { throw 'params_required' }
            $r = Test-ModelChat $edition $patch $originalId $idxHint
            Write-Log ("models test-chat: {0} id={1} ok={2} code={3} status={4} url={5} fixed={6}" -f `
                       $edition, ([string]$patch.id), $r.ok, $r.code, $r.status, $r.chatUrl, $r.fixedUrl)
            return $r
        }

        '/api/models/test' {
            $edition = ''
            $originalId = ''
            $patch = $null
            if ($body) {
                $edition = [string]$body.edition
                $originalId = [string]$body.originalId
                $patch = $body.model
            }
            if (-not (Test-Edition $edition)) { throw 'unknown_edition' }
            if ($null -eq $patch) { throw 'params_required' }
            $listOnly = $false
            if ($null -ne $body.PSObject.Properties['listOnly']) { $listOnly = [bool]$body.listOnly }
            $r = Test-ModelUsable $edition $patch $originalId $listOnly
            Write-Log ("models test: {0} id={1} ok={2} stage={3} code={4} status={5}" -f `
                       $edition, ([string]$patch.id), $r.ok, $r.stage, $r.code, $r.status)
            return $r
        }

        '/api/recover/list' {
            $edition = ''
            if ($query.ContainsKey('edition')) { $edition = $query['edition'] }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            $r = Get-RecoverCandidates $edition
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($s in $r.sessions) {
                $nick = Get-Nickname $edition $s.uid
                $items.Add([pscustomobject]@{
                    id        = $s.id
                    title     = $s.title
                    slug      = $s.slug
                    uid       = $s.uid
                    shortUid  = (Get-DisplayName $s.uid)
                    nickname  = $nick
                    space     = $s.space
                    bytes     = $s.bytes
                    updatedMs = $s.updatedMs
                    state     = $s.state
                    archived  = $s.archived
                    deleted   = $s.deleted
                    mine      = $s.mine
                    defaultOn = $s.defaultOn
                })
            }
            return [pscustomobject]@{
                ok         = $true
                edition    = $edition
                account    = [pscustomobject]@{
                    uid     = $r.account.uid
                    uinMask = (Mask-Uin $r.account.uin)
                    nickname = (Get-Nickname $edition $r.account.uid)
                }
                total      = $items.Count
                unattached = $r.unattached
                cloud      = $r.cloud
                archived   = $r.archived
                deleted    = $r.deleted
                sessions   = $items.ToArray()
            }
        }

        '/api/recover/apply' {
            $edition = ''
            $ids = @()
            $doBackup = $true
            if ($body) {
                if ($body.edition) { $edition = [string]$body.edition }
                if ($body.ids) { $ids = @($body.ids) }
                if ($null -ne $body.backup) { $doBackup = [bool]$body.backup }
            }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }
            if ($ids.Count -eq 0) { throw 'nothing_to_recover' }
            $r = Invoke-RecoverSessions $edition $ids $doBackup
            return $r
        }

        '/api/accounts/delete' {
            $product = ''
            $uid = ''
            if ($body) { $product = [string]$body.product; $uid = [string]$body.uid }
            if (-not $product -or -not $uid) { throw 'params_required' }
            foreach ($f in @((Get-ProfileInfoPath $product $uid), (Get-ProfileMetaPath $product $uid))) {
                if (Test-Path -LiteralPath $f) {
                    $e2 = $null
                    try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { $e2 = $_ }
                    if (Test-Path -LiteralPath $f) { throw ('delete_failed: ' + (Get-ErrMessage $e2)) }
                }
            }
            Write-Log ("profile deleted: {0} {1}" -f $product, $uid)
            return [pscustomobject]@{ ok = $true }
        }

        '/api/client/start' {
            $product = Get-ActiveEdition
            if ($body -and $body.product) { $product = [string]$body.product }
            if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
            $r = Start-Client $product
            return [pscustomobject]@{ ok = $true; edition = $product; started = $r.started; exe = $r.exe; reason = [string]$r.reason }
        }

        '/api/client/stop' {
            $product = Get-ActiveEdition
            if ($body -and $body.product) { $product = [string]$body.product }
            if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
            $stopped = Stop-Client (Get-ProductProc $product)
            $reason = ''
            if ($NoProcessControl) { $reason = 'process_control_disabled' }
            return [pscustomobject]@{ ok = $true; edition = $product; stopped = $stopped; reason = $reason }
        }

        '/api/client/restart' {
            $product = Get-ActiveEdition
            if ($body -and $body.product) { $product = [string]$body.product }
            if (-not (Test-Edition $product)) { $product = Get-ActiveEdition }
            # stop first: launching a second instance just focuses the running one,
            # it does not restart it
            $stopped = Stop-Client (Get-ProductProc $product)
            $r = Start-Client $product
            return [pscustomobject]@{ ok = $true; edition = $product; stopped = $stopped; started = $r.started; exe = $r.exe; reason = [string]$r.reason }
        }

        '/api/open' {
            $target = 'root'
            if ($body -and $body.target) { $target = [string]$body.target }
            $edition = ''
            if ($body -and $body.edition) { $edition = [string]$body.edition }
            if (-not (Test-Edition $edition)) { $edition = Get-ActiveEdition }

            # 'group-file': hand ONE models file to whatever program owns .json,
            # so the user can edit it in their own editor. Distinct from every
            # other target because those open a FOLDER in Explorer, while this
            # must be a bare path (no explorer.exe in front) or Windows would
            # just highlight the file instead of opening it.
            if ($target -eq 'group-file') {
                $file = ''
                if ($body -and $body.file) { $file = [string]$body.file }
                if (-not $file) { throw 'group_required' }
                # Same validation the group routes use: one leaf name, and it
                # has to look like one of our files.
                if ($file -ne [IO.Path]::GetFileName($file)) { throw 'bad_group_name' }
                if (-not (Test-GroupFile $file)) { throw 'bad_group_name' }
                $dir = Get-EditionHome $edition
                $p = Join-Path $dir $file
                if (-not (Test-Path -LiteralPath $p)) { throw 'group_not_found' }
                Start-Process -FilePath $p | Out-Null
                Write-Log ("open group file: {0} {1}" -f $edition, $file)
                return [pscustomobject]@{ ok = $true; path = $p; file = $file }
            }

            $p = $Root
            if ($target -eq 'backups') { $p = $BackupsDir }
            elseif ($target -eq 'profiles') { $p = $ProfilesDir }
            elseif ($target -eq 'workbuddy') { $p = (Get-EditionHome $edition) }
            elseif ($target -eq 'auth') { $p = $AuthDir }
            elseif ($target -eq 'app') { $p = $ScriptDir }
            if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p | Out-Null }
            return [pscustomobject]@{ ok = $true; path = $p }
        }

        '/api/ping' { return [pscustomobject]@{ ok = $true; ts = (Get-NowMs) } }

        '/api/shortcut/create' {
            $r = New-DesktopShortcut
            return $r
        }

        '/api/quit' {
            $script:QuitRequested = $true
            return [pscustomobject]@{ ok = $true }
        }

        default { throw 'not_found' }
    }
}

function Handle-Client($client) {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 15000
    $req = $null
    try { $req = Read-HttpRequest $stream } catch { $req = $null }
    if (-not $req) { return }

    $target = $req.target
    $qIdx = $target.IndexOf('?')
    $path = $target
    $qs = ''
    if ($qIdx -ge 0) { $path = $target.Substring(0, $qIdx); $qs = $target.Substring($qIdx + 1) }
    $query = Parse-Query $qs

    $script:LastPing = Get-Date
    $script:Pinged = $true

    try {
        # The Host header must name this loopback server. Without this check a
        # web page can point a hostname it controls at 127.0.0.1 (DNS rebinding)
        # and then talk to us as a same-origin peer - it would reach both the
        # token below and every /api/* route. Legitimate callers are the app
        # window and any /api client, all of which use 127.0.0.1 or localhost.
        $hostHdr = ''
        if ($req.headers.ContainsKey('host')) { $hostHdr = [string]$req.headers['host'] }
        $port = [int]$script:ListenPort
        $okHost = @(
            ('127.0.0.1:' + $port), ('localhost:' + $port),
            ('[::1]:' + $port), ('::1:' + $port)
        )
        if ($hostHdr -and ($okHost -notcontains $hostHdr)) {
            Write-Log ('rejected request with unexpected Host: ' + $hostHdr)
            Send-Json $stream ([pscustomobject]@{ ok = $false; code = 'forbidden'; error = 'unexpected host' }) 403
            return
        }

        if ($req.method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            # The page is served with the real token substituted into it, so it
            # is a credentialed document: it must not be readable without the
            # token. The launch URL already carries ?t=, so a legitimate window
            # loads fine; anything else gets nothing to read. Without this, any
            # local process could GET / and walk away with the token that gates
            # /api/accounts/switch, /api/purge/apply and /api/backup/restore.
            $t = ''
            if ($query.ContainsKey('t')) { $t = $query['t'] }
            if (-not $t -and $req.headers.ContainsKey('x-wb-token')) { $t = $req.headers['x-wb-token'] }
            if ($t -ne $script:Token) {
                Send-Json $stream ([pscustomobject]@{ ok = $false; code = 'forbidden'; error = 'invalid token' }) 403
                return
            }
            if (-not (Test-Path -LiteralPath $UiPath)) {
                Send-Bytes $stream 500 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('ui.html not found next to app.ps1'))
                return
            }
            $html = [IO.File]::ReadAllText($UiPath, [Text.Encoding]::UTF8)
            $html = $html.Replace('__WB_TOKEN__', $script:Token)
            Send-Bytes $stream 200 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($html))
            return
        }

        if ($path.StartsWith('/api/')) {
            $token = ''
            if ($query.ContainsKey('t')) { $token = $query['t'] }
            if (-not $token -and $req.headers.ContainsKey('x-wb-token')) { $token = $req.headers['x-wb-token'] }
            if ($token -ne $script:Token) {
                Send-Json $stream ([pscustomobject]@{ ok = $false; code = 'forbidden'; error = 'invalid token' }) 403
                return
            }
            $script:Busy = $true
            try {
                $res = Invoke-Api $path $query $req
                Send-Json $stream $res 200
            } catch {
                $code = 'error'
                $msg = Get-ErrMessage $_.Exception
                Send-Json $stream ([pscustomobject]@{ ok = $false; code = $code; error = $msg }) 400
                $pos = ''
                try { $pos = $_.InvocationInfo.PositionMessage } catch { }
                Write-Log ('api error ' + $path + ': ' + $msg + ' @ ' + $pos)
            } finally {
                $script:Busy = $false
                $script:LastPing = Get-Date
            }
            if ($script:QuitRequested) { Start-Sleep -Milliseconds 250 }
            return
        }

        Send-Json $stream ([pscustomobject]@{ ok = $false; code = 'not_found' }) 404
    } catch {
        Write-Log ('http error: ' + (Get-ErrMessage $_.Exception))
    } finally {
        try { $stream.Close() } catch { }
    }
}

# --------------------------------------------------------------------------
# browser window
# --------------------------------------------------------------------------
function Find-AppBrowser {
    $cands = New-Object System.Collections.Generic.List[string]
    $suffixes = @(
        'Microsoft\Edge\Application\msedge.exe',
        'Google\Chrome\Application\chrome.exe',
        'Chromium\Application\chrome.exe'
    )
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($s in $suffixes) {
            $p = Join-Path $base $s
            if (Test-Path -LiteralPath $p) { $cands.Add($p) }
        }
    }
    if ($cands.Count -gt 0) { return $cands[0] }
    return ''
}

# --------------------------------------------------------------------------
# window probe
#
# The backend is only useful while its window is on screen. Browsers throttle
# timers in a window that is not in front (down to once a minute), so "no ping
# for 28s" was killing the server while the user was simply reading. Instead of
# guessing from pings alone we also look for the window itself: once we have
# opened it and it disappears for good, the process shuts down and cleans up.
# --------------------------------------------------------------------------
$script:WinReady = $false

function Initialize-WindowProbe {
    if ($script:WinReady) { return }
    $code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WbWin
{
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();

    public static IntPtr FindWindowByTitle(string needle)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            int n = GetWindowTextLength(h);
            if (n <= 0) return true;
            StringBuilder sb = new StringBuilder(n + 1);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool AnyWindowWithTitle(string needle)
    {
        return FindWindowByTitle(needle) != IntPtr.Zero;
    }

    public static uint GetWindowPid(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static bool CloseWindow(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
    }

    public static bool BringToFront(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        ShowWindow(h, 9);                       // SW_RESTORE, in case it is minimised
        if (SetForegroundWindow(h)) return true;

        // Windows refuses SetForegroundWindow when the caller is not already the
        // foreground process (our process has no window at all). Attaching to the
        // current foreground thread lifts that restriction.
        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint me = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != me) attached = AttachThreadInput(me, fgThread, true);
        bool ok = SetForegroundWindow(h);
        if (attached) AttachThreadInput(me, fgThread, false);
        if (!ok)
        {
            SwitchToThisWindow(h, true);        // last resort, more permissive
            ok = true;
        }
        return ok;
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp
    $script:WinReady = $true
}

function Test-AppWindowAlive {
    try {
        Initialize-WindowProbe
        return [WbWin]::AnyWindowWithTitle($script:WindowTitle)
    } catch {
        return $true    # never kill the session over a probe failure
    }
}

function Get-AppWindowHandle {
    # IntPtr.Zero = no such window; $null = the probe itself is unavailable
    try {
        Initialize-WindowProbe
        return [WbWin]::FindWindowByTitle($script:WindowTitle)
    } catch {
        return $null
    }
}

function Focus-AppWindow {
    $h = Get-AppWindowHandle
    if ($null -eq $h -or $h -eq [IntPtr]::Zero) { return $false }
    try { return [WbWin]::BringToFront($h) } catch { return $false }
}

function Test-OurBrowserWindow([IntPtr]$h) {
    # Only windows opened by the private browser profile we create are safe to
    # close. If the user happens to have the page in an ordinary tab, closing that
    # window would take all their other tabs with it - so check the owner first.
    try {
        $procId = [WbWin]::GetWindowPid($h)
        if ($procId -le 0) { return $false }
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $procId) -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.CommandLine) { return $false }
        $profileDir = Join-Path $DataDir 'window-profile'
        return ($p.CommandLine.IndexOf($profileDir, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } catch {
        return $false
    }
}

function Close-AppWindow {
    # A window whose backend is gone is just a broken page; close it so the new
    # launch does not end up with two windows.
    $h = Get-AppWindowHandle
    if ($null -eq $h -or $h -eq [IntPtr]::Zero) { return $false }
    if (-not (Test-OurBrowserWindow $h)) {
        Write-Log 'stale window does not belong to our browser profile; leaving it open'
        return $false
    }
    try { [void][WbWin]::CloseWindow($h) } catch { return $false }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-AppWindowHandle)) { break }
        $now = Get-AppWindowHandle
        if ($null -eq $now -or $now -eq [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 150
    }
    return $true
}

function Start-AppWindow([string]$url) {
    if ($NoBrowser) { return $false }
    $profileDir = Join-Path $DataDir 'window-profile'
    if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $browser = Find-AppBrowser
    if ($browser) {
        $bargs = @(
            "--app=$url",
            "--window-size=1220,800",
            "--window-position=140,80",
            "--user-data-dir=$profileDir",
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-features=Translate,msEdgeSplitScreen',
            '--no-service-autorun'
        )
        try {
            Start-Process -FilePath $browser -ArgumentList $bargs | Out-Null
            return $true
        } catch {
            Write-Log ('browser launch failed: ' + (Get-ErrMessage $_.Exception))
        }
    }
    try {
        Start-Process $url | Out-Null
        return $true
    } catch { }
    return $false
}

function Test-PortOpen([int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(400)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $c.Close()
        return $true
    } catch { return $false }
}

function Stop-StaleBackend($inst) {
    # A backend whose window is gone is a leftover: the window was closed but the
    # process never noticed (browser killed, crash, sleep/resume). Take it down so
    # the new launch can own the port and the instance file.
    if (-not $inst) { return $false }
    $procId = 0
    try { $procId = [int]$inst.pid } catch { }
    if ($procId -le 0) { return $false }

    # never kill a recycled pid: make sure that process is still our script
    $p = $null
    try { $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $procId) -ErrorAction SilentlyContinue } catch { }
    if (-not $p) { return $false }
    if (-not $p.CommandLine -or $p.CommandLine -notmatch 'app\.ps1') { return $false }

    Write-Log ("stopping stale backend: pid={0} port={1}" -f $procId, $inst.port)
    try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { }

    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PortOpen ([int]$inst.port))) { break }
        Start-Sleep -Milliseconds 200
    }
    return $true
}

# Sizes baked into the .ico. The shell does not scale nicely between frames: it
# takes the one closest to the size it needs and stretches it, so any gap in this
# list shows up as stair steps on the desktop. A desktop icon is not always 48 or
# 96 - the size slider allows values like 81 - which is why the ladder is denser
# than the traditional four, and why 80 sits next to 96: it is the frame an 81px
# desktop actually lands on.
$script:AppIconSizes = @(16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 256)

function Get-AppIconInk([System.Drawing.Bitmap]$bmp) {
    # Bounding box of every pixel that is not transparent. GDI+ centres the font's
    # line box, not the ink inside it, so "WB" lands a pixel or two left and high
    # on the small frames. Measuring the ink is the only way to put it dead centre
    # without hard coding the metrics of one particular font.
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle -ArgumentList @(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    } finally {
        $bmp.UnlockBits($data)
    }

    $minX = $w; $maxX = -1; $minY = $h; $maxY = -1
    for ($y = 0; $y -lt $h; $y++) {
        $row = $y * $stride
        for ($x = 0; $x -lt $w; $x++) {
            if ($buf[$row + ($x * 4) + 3] -gt 8) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return $null }
    return [pscustomobject]@{ left = $minX; right = $maxX; top = $minY; bottom = $maxY }
}

function New-AppIconBitmap([int]$size) {
    # Draw the WB mark at the exact size it will be shown at. Rendering every
    # frame separately is the whole point: a 48px frame drawn at 48px is sharp,
    # a 256px frame shrunk to 48px by the shell is not.
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList @($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded square, same 11/36 corner ratio the page uses
    $edge = [double]$size
    $r = $edge * 11.0 / 36.0
    if ($r -lt 1.0) { $r = 1.0 }
    $d = $r * 2.0
    $shape = New-Object System.Drawing.Drawing2D.GraphicsPath
    $shape.AddArc(0, 0, $d, $d, 180, 90)
    $shape.AddArc($edge - $d, 0, $d, $d, 270, 90)
    $shape.AddArc($edge - $d, $edge - $d, $d, $d, 0, 90)
    $shape.AddArc(0, $edge - $d, $d, $d, 90, 90)
    $shape.CloseFigure()

    $c1 = [System.Drawing.Color]::FromArgb(255, 0x4a, 0x86, 0xff)
    $c2 = [System.Drawing.Color]::FromArgb(255, 0x2f, 0x4f, 0xf6)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList @(
        (New-Object System.Drawing.Point -ArgumentList @(0, 0)),
        (New-Object System.Drawing.Point -ArgumentList @([int]$size, [int]$size)),
        $c1, $c2)
    $g.FillPath($brush, $shape)

    # "WB" only reads from 32px up. Below that the two letters collapse into an
    # unreadable smudge, so the small frames carry one large "W" instead - that
    # is why the tiny icon and the big icon are not simply scaled copies.
    if ($size -ge 32) { $text = 'WB'; $ratio = 0.36 } else { $text = 'W'; $ratio = 0.70 }
    # whole pixel font sizes only. A fractional size makes GDI+ spread the stems
    # over sub-pixels, and at 16-24px that is the difference between a crisp "W"
    # and a grey smudge.
    $px = [float][Math]::Round($edge * $ratio)
    if ($px -lt 6.0) { $px = 6.0 }
    $font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', $px, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center

    # The letters go on a transparent layer of their own: measuring them is only
    # possible while nothing else is on the bitmap, and moving a layer does not
    # drag the rounded square along with it.
    $layer = New-Object System.Drawing.Bitmap -ArgumentList @($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $lg = [System.Drawing.Graphics]::FromImage($layer)
    $lg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $lg.Clear([System.Drawing.Color]::Transparent)
    $white = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::White)
    $box = New-Object System.Drawing.RectangleF -ArgumentList @([float]0, [float]0, [float]$size, [float]$size)
    $lg.DrawString($text, $font, $white, $box, $fmt)
    $lg.Dispose()

    $ink = Get-AppIconInk $layer
    if ($ink) {
        $shiftX = [int][Math]::Round(($size - ($ink.right - $ink.left + 1)) / 2.0) - $ink.left
        $shiftY = [int][Math]::Round(($size - ($ink.bottom - $ink.top + 1)) / 2.0) - $ink.top
        $g.DrawImageUnscaled($layer, $shiftX, $shiftY)
    }
    $g.Dispose()
    $layer.Dispose()

    $fmt.Dispose()
    $font.Dispose()
    $white.Dispose()
    $brush.Dispose()
    $shape.Dispose()
    return $bmp
}

function Test-AppIconCurrent([string]$path) {
    # Earlier builds wrote a single 256px frame. Windows then had no matching
    # frame and scaled that one bitmap down to whatever Explorer asked for
    # (16 on the taskbar, 32/48 on the desktop), which is exactly the blocky
    # look this function guards against. Reusing such a file would keep the
    # artefact forever, so the frame count decides whether it can be reused.
    try {
        $fs = [IO.File]::OpenRead($path)
        try {
            $buf = New-Object byte[] 6
            $n = $fs.Read($buf, 0, 6)
        } finally { $fs.Close() }
        if ($n -lt 6) { return $false }
        $count = [int]$buf[4] + ([int]$buf[5] * 256)
        return ($count -eq $script:AppIconSizes.Count)
    } catch { return $false }
}

function New-AppIcon {
    # The launcher has no icon of its own, and borrowing WorkBuddy's would suggest
    # this is WorkBuddy itself. So draw the same "WB" mark the page shows in its
    # top-left corner and keep it as a small .ico in the data folder.
    $icoPath = Join-Path $DataDir 'app.ico'
    if (Test-Path -LiteralPath $icoPath) {
        if (Test-AppIconCurrent $icoPath) { return $icoPath }
        Write-Log 'app icon: old single frame icon found, rebuilding with every size'
    }
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

    Add-Type -AssemblyName System.Drawing
    $frames = @()
    foreach ($s in $script:AppIconSizes) {
        $bmp = New-AppIconBitmap $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames += ,([pscustomobject]@{ size = $s; bytes = $ms.ToArray() })
        $ms.Dispose()
        $bmp.Dispose()
    }

    # An .ico is one directory followed by the raw images. Offsets are absolute,
    # so they can only be filled in once the header size is known.
    $offset = 6 + 16 * $frames.Count
    $tmp = $icoPath + '.tmp'
    $fs = [IO.File]::Create($tmp)
    $bw = New-Object System.IO.BinaryWriter -ArgumentList @($fs)
    try {
        $bw.Write([uint16]0)                 # reserved
        $bw.Write([uint16]1)                 # type: icon
        $bw.Write([uint16]$frames.Count)     # how many images follow
        foreach ($f in $frames) {
            $dim = [int]$f.size
            # the width and height fields are one byte each, so 256 is stored as 0
            if ($dim -ge 256) { $bw.Write([byte]0); $bw.Write([byte]0) }
            else { $bw.Write([byte]$dim); $bw.Write([byte]$dim) }
            $bw.Write([byte]0)               # palette entries
            $bw.Write([byte]0)               # reserved
            $bw.Write([uint16]1)             # colour planes
            $bw.Write([uint16]32)            # bits per pixel
            $bw.Write([uint32]$f.bytes.Length)
            $bw.Write([uint32]$offset)
            $offset += $f.bytes.Length
        }
        foreach ($f in $frames) { $bw.Write($f.bytes) }
        $bw.Flush()
    } finally {
        $bw.Close()
    }
    # write to a temp name first: a half written icon is worse than an old one
    Move-Item -LiteralPath $tmp -Destination $icoPath -Force
    Write-Log ("app icon written: {0} sizes, {1} bytes" -f $frames.Count, (Get-Item -LiteralPath $icoPath).Length)
    return $icoPath
}

function New-ShortcutIn([string]$folder, [string]$name, [string]$launchFile, [string]$icon) {
    $lnk = Join-Path $folder $name
    $existed = Test-Path -LiteralPath $lnk
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { throw 'wscript_missing' }
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
    $sc.Arguments = '"' + $launchFile + '"'
    $sc.WindowStyle = 1
    $sc.WorkingDirectory = $ScriptDir
    $sc.Description = $name
    if ($icon -and (Test-Path -LiteralPath $icon)) { $sc.IconLocation = ($icon + ',0') }
    $sc.Save()
    # CreateShortcut + Save can fail silently when the folder is read-only or
    # redirected, so verify instead of trusting the COM call.
    if (-not (Test-Path -LiteralPath $lnk)) { throw 'shortcut_not_written' }
    return [pscustomobject]@{ ok = $true; path = $lnk; name = $name; existed = $existed; icon = $icon; dir = $folder }
}

function New-DesktopShortcut {
    # A .lnk that points at the hidden .vbs launcher, so double-clicking it
    # behaves exactly like the original entry point (including the single
    # instance check) and opens no console window at all.
    # The launcher name is Chinese, so it is discovered rather than typed.
    $launcher = @(Get-ChildItem -LiteralPath $ScriptDir -Filter '*.vbs' -File -ErrorAction SilentlyContinue |
                  Sort-Object Name | Select-Object -First 1)
    if (-not $launcher.Count) { throw 'launcher_missing' }
    $launchFile = $launcher[0]

    $name = [IO.Path]::GetFileNameWithoutExtension($launchFile.Name)
    # drop the leading verb ("<chinese> ") so the icon reads as the product name
    $m = [regex]::Match($name, '[A-Za-z0-9]')
    if ($m.Success -and $m.Index -gt 0) { $name = $name.Substring($m.Index) }
    $name = $name + '.lnk'

    # the program's own WB mark, not WorkBuddy's - otherwise the two look identical
    $icon = ''
    try { $icon = New-AppIcon } catch { Write-Log ('app icon failed: ' + $_.Exception.Message) }

    # Desktop first. If that is unavailable (no profile desktop, OneDrive
    # redirection that the process cannot see, locked down by policy), fall back
    # to the folder the program itself lives in: the user still gets something
    # double-clickable, and the window says where it went.
    $desktop = [Environment]::GetFolderPath('Desktop')
    $firstError = 'desktop_missing'
    if ($desktop -and (Test-Path -LiteralPath $desktop)) {
        try {
            $r = New-ShortcutIn $desktop $name $launchFile.FullName $icon
            $r | Add-Member -NotePropertyName fallback -NotePropertyValue $false
            $r | Add-Member -NotePropertyName reason -NotePropertyValue ''
            Write-Log ("desktop shortcut: {0}" -f $r.path)
            return $r
        } catch {
            $firstError = $_.Exception.Message
            Write-Log ('desktop shortcut failed: ' + $firstError)
        }
    }

    $r = New-ShortcutIn $ScriptDir $name $launchFile.FullName $icon
    $r | Add-Member -NotePropertyName fallback -NotePropertyValue $true
    $r | Add-Member -NotePropertyName reason -NotePropertyValue $firstError
    Write-Log ("app folder shortcut: {0} (desktop failed: {1})" -f $r.path, $firstError)
    return $r
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
$existing = Read-JsonFile $script:InstancePath
$serving = $false
if ($existing -and $existing.port -and $existing.token) {
    if (Test-PortOpen ([int]$existing.port)) { $serving = $true }
}

# What a second double-click should do depends on what is actually still there:
#
#   serving + window   -> do nothing new, just raise the window we already have
#   serving, no window -> leftover; take it down and start properly
#   not serving        -> any process still holding the record is a zombie, clear it
#   nothing at all     -> normal start
#
# instance.json / url.txt are only written by whoever ends up owning the instance.
$script:OwnsInstance = $true
if ($Port) {
    # explicit port (tests, side-by-side runs): leave any other instance alone
    if ($serving) {
        $script:OwnsInstance = $false
        Write-Log ("another instance is serving on port {0}; not touching instance.json" -f [int]$existing.port)
    }
} else {
    $h = Get-AppWindowHandle
    $hasWin = ($null -ne $h -and $h -ne [IntPtr]::Zero)
    if ($serving) {
        if ($hasWin) {
            Write-Log 'duplicate launch: window already open, bringing it to front'
            [void](Focus-AppWindow)
            exit 0
        }
        Write-Log ("backend on port {0} is serving but has no window; taking it down" -f [int]$existing.port)
        [void](Stop-StaleBackend $existing)
    } else {
        # nothing is serving: a lingering process and an orphan window are both
        # dead weight - clear them so we start from a clean slate
        if ($existing) { [void](Stop-StaleBackend $existing) }
        if ($hasWin) {
            Write-Log 'window without backend: closing it, then starting fresh'
            [void](Close-AppWindow)
        }
    }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch {
    Write-Log ('cannot bind listener: ' + (Get-ErrMessage $_.Exception))
    exit 1
}
$actualPort = [int]$listener.LocalEndpoint.Port
# Kept in a script-scoped variable so request handling can validate the Host
# header against the port we really bound, rather than reaching up the call
# stack for $actualPort (which only works by dynamic scoping).
$script:ListenPort = $actualPort

$chars = 'abcdefghijkmnpqrstuvwxyz23456789'
$tok = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 28; $i++) { [void]$tok.Append($chars[(Get-Random -Maximum $chars.Length)]) }
$script:Token = $tok.ToString()

$url = "http://127.0.0.1:$actualPort/?t=$($script:Token)"
if ($script:OwnsInstance) {
    Write-JsonFile $script:InstancePath ([pscustomobject]@{
        port = $actualPort; token = $script:Token; pid = $PID
        startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    })
    [IO.File]::WriteAllText((Join-Path $DataDir 'url.txt'), $url, (New-Object System.Text.UTF8Encoding($false)))
}
Write-Log ("started v{0} port={1} root={2}" -f $AppVersion, $actualPort, $Root)

if (Start-AppWindow $url) { $script:WindowWatch = $true }

$script:QuitRequested = $false
while ($true) {
    try {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try { Handle-Client $client } catch { Write-Log ('handler: ' + (Get-ErrMessage $_.Exception)) }
            finally { try { $client.Close() } catch { } }
        } else {
            Start-Sleep -Milliseconds 40
            $now = Get-Date
            if (($now - $script:LastTick).TotalSeconds -ge 20) {
                $script:LastTick = $now
                try { Sync-Profiles } catch { }
            }
            if ($script:QuitRequested) { break }
            if (-not $script:Busy -and -not $KeepAlive) {
                # Closing the window is the normal way out: watch for it directly.
                # Only enforced after we have actually seen the window once, and
                # only while the page is quiet, so a probe quirk can never kill a
                # session that is being used.
                if ($script:WindowWatch -and ($now - $script:LastWinCheck).TotalSeconds -ge 5) {
                    $script:LastWinCheck = $now
                    if (Test-AppWindowAlive) {
                        $script:SawWindow = $true
                        $script:WinGone = 0
                    } elseif ($script:SawWindow -and ($now - $script:LastPing).TotalSeconds -gt 20) {
                        $script:WinGone++
                        if ($script:WinGone -ge 4) { Write-Log 'window closed'; break }
                    }
                }
                $idle = ($now - $script:LastPing).TotalSeconds
                # 100s, not 28s: a window that is not in front gets its timers
                # throttled to roughly one ping a minute, which used to look like
                # "the user left" after half a minute.
                if ($script:Pinged -and $idle -gt 100) { Write-Log 'idle exit'; break }
                if (-not $script:Pinged -and ($now - $script:StartAt).TotalSeconds -gt 150) { Write-Log 'no ui attached'; break }
            }
        }
    } catch {
        Write-Log ('loop: ' + (Get-ErrMessage $_.Exception))
        Start-Sleep -Milliseconds 200
    }
}

try { $listener.Stop() } catch { }
try {
    $inst = Read-JsonFile $script:InstancePath
    if ($script:OwnsInstance -and $inst -and [int]$inst.pid -eq $PID) {
        Remove-Item -LiteralPath $script:InstancePath -Force -ErrorAction SilentlyContinue
    }
} catch { }
Write-Log 'stopped'
