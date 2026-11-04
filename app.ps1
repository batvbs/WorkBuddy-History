<#
  WorkBuddy Keeper 1.5.5
  Session backup / restore + account switch for the WorkBuddy desktop client.
  Supports both editions (China and international) side by side.

  Design notes
  - Zero dependency: runs on the Windows PowerShell 5.1 that ships with Windows 10/11.
  - No SQLite, no external modules, no network access. Everything is plain file copying.
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

$AppVersion = '1.5.5'

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

function Copy-Tree([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
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

function Get-DbOwnerCount([string]$dbPath, [string]$uid) {
    $db = Open-WbDatabasePath $dbPath
    try {
        $rows = [WbSqlite]::Query($db, 'SELECT count(*) AS n FROM sessions WHERE user_id=?1', @($uid))
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
            $n = [WbSqlite]::Exec($db, 'UPDATE sessions SET user_id=?1 WHERE user_id=?2', @($newUid, $oldUid))
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

function Merge-DbSessions([string]$product, [string]$srcDbPath) {
    # "Fill in what is missing" for the database: copy the rows that the target
    # does not have yet, leave everything else alone.
    # The two editions may not be on the same schema version, so only the columns
    # that exist on both sides are copied - a missing column simply keeps its
    # default instead of blowing up the whole restore.
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
            [void][WbSqlite]::Exec($db, 'BEGIN IMMEDIATE', $null)
            try {
                $n = [WbSqlite]::Exec($db,
                    ("INSERT OR IGNORE INTO sessions ({0}) SELECT {0} FROM src.sessions" -f $colList), $null)
                [void][WbSqlite]::Exec($db, 'COMMIT', $null)
            } catch {
                [void][WbSqlite]::Exec($db, 'ROLLBACK', $null)
                throw
            }
            [void][WbSqlite]::Query($db, 'PRAGMA wal_checkpoint(TRUNCATE)', $null)
            $chk = [WbSqlite]::Query($db, 'PRAGMA integrity_check', $null)
            if (-not $chk.Count -or [string]$chk[0]['integrity_check'] -ne 'ok') { throw 'integrity_check_failed' }
            Write-Log ("db merge: {0} rows inserted from {1}" -f $n, $srcDbPath)
            return $n
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
    $snapName = ''
    if ($Backup) {
        try {
            $m = New-Backup $true 'pre-recover' '' $product
            if ($m) { $snapName = [string]$m.name }
        } catch {
            Write-Log ('pre-recover backup failed: ' + $_.Exception.Message)
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
    $snapName = ''
    if ($Backup) {
        try {
            $m = New-Backup $true 'pre-purge' '' $product
            if ($m) { $snapName = [string]$m.name }
        } catch {
            Write-Log ('pre-purge backup failed: ' + $_.Exception.Message)
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

    # never lose the token of the account we are leaving
    try { [void](Save-Profile $product) } catch { Write-Log 'skip saving current login (none)' }

    $wasRunning = ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0)
    # only touch the client of the product line we are switching
    [void](Stop-Client (Get-ProductProc $product))

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

    # The whole point of "log in a new account" is that the old one must not be
    # lost, so saving the current login state is a hard prerequisite: if it fails
    # we stop here instead of clearing a login we could not back up.
    $saved = $null
    try { $saved = Save-Profile $product } catch {
        Write-Log ('save before logout failed: ' + $_.Exception.Message)
        throw 'save_before_logout_failed'
    }

    $wasRunning = ((Get-ClientProcesses (Get-ProductProc $product)).Count -gt 0)
    [void](Stop-Client (Get-ProductProc $product))

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
            Copy-Tree $attSrc $attDst
            $inner = Get-ChildItem -LiteralPath $attSrc -Recurse -File -Force -ErrorAction SilentlyContinue
            $fileCount += [int]($inner | Measure-Object).Count
            $totalBytes += (Get-FolderSize $attSrc)
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

function Restore-Backup([string]$name, [string]$mode, [bool]$remap, [string]$targetEdition) {
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
    $procName = Get-ProductProc $product

    $wasRunning = ((Get-ClientProcesses $procName).Count -gt 0)
    if ($wasRunning) {
        [void](Stop-Client $procName)
        Start-Sleep -Milliseconds 600
    }

    # safety net: snapshot the current state first.
    # A cross edition restore always takes one, even in merge mode, because it may
    # mix data from two different clients.
    $pre = $null
    if ($mode -eq 'full' -or $crossEdition) {
        try { $pre = New-Backup ([bool]$mf.includeAttachments) 'pre-restore' '' $product } catch { Write-Log ('pre-restore backup failed: ' + $_.Exception.Message) }
    }

    $restored = 0
    $merged = 0
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
                $old = ''
                if ($mf.account -and $mf.account.uid) { $old = [string]$mf.account.uid }
                $chk = Test-RemapSafe $stageDb $old ($(if ($cur) { $cur.uid } else { '' }))
                if ($chk.ok) {
                    try { [void](Invoke-UidRemap $stageDb $old $cur.uid); $remapDone = $true }
                    catch { $remapReason = 'remap_failed'; Write-Log ('remap failed: ' + $_.Exception.Message) }
                } else {
                    $remapReason = [string]$chk.reason
                }
            }

            if ($mode -eq 'full') {
                Remove-Item -LiteralPath ($dbDst + '-wal') -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath ($dbDst + '-shm') -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $stageDb -Destination $dbDst -Force
            } else {
                $merged = Merge-DbSessions $product $stageDb
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
                Copy-Item -LiteralPath $f.FullName -Destination $target -Force
                $restored++
            }
            foreach ($sd in @(Get-ChildItem -LiteralPath $slugDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $target = Join-Path $dst $sd.Name
                if ($mode -eq 'merge' -and (Test-Path -LiteralPath $target)) { continue }
                Copy-Tree $sd.FullName $target
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
            Copy-Item -LiteralPath $snap -Destination $dstSnap -Force
        }
    }

    $script:SessionCache = @{}
    $script:SessionCacheAt = @{}

    # Deliberately NOT restarting the client here: the page asks the user whether
    # to open it, and only starts it if they say yes.
    Write-Log ("restore done: {0} edition={1} from={2} cross={3} mode={4} files={5} merged={6} remap={7}" -f $name, $product, $sourceEdition, $crossEdition, $mode, $restored, $merged, $remapDone)
    return [pscustomobject]@{
        ok            = $true
        mode          = $mode
        edition       = $product
        sourceEdition = $sourceEdition
        crossEdition  = $crossEdition
        home          = $edHome
        files         = $restored
        merged        = $merged
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

        '/api/backup/restore' {
            $name = ''
            if ($body) { $name = [string]$body.name }
            $mode = 'full'
            if ($body -and $body.mode) { $mode = [string]$body.mode }
            $remap = $false
            if ($body -and $null -ne $body.remap) { $remap = [bool]$body.remap }
            $target = ''
            if ($body -and $body.target) { $target = [string]$body.target }
            $r = Restore-Backup $name $mode $remap $target
            return $r
        }

        '/api/backup/delete' {
            $name = ''
            if ($body) { $name = [string]$body.name }
            if (-not $name) { throw 'name_required' }
            $dir = Join-Path $BackupsDir $name
            if (-not (Test-Path -LiteralPath $dir)) { throw 'backup_missing' }
            $full = [IO.Path]::GetFullPath($dir)
            if (-not $full.StartsWith([IO.Path]::GetFullPath($BackupsDir))) { throw 'invalid_path' }
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
        if ($req.method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
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
