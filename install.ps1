#Requires -Version 5.1
<#
.SYNOPSIS
    Symlinks the agents repository into the dotfile directories read by
    Claude Code, OpenAI Codex CLI, and Gemini CLI under %USERPROFILE%.

.DESCRIPTION
    Idempotent. Re-running with no flags is a no-op when all links are
    already correct. Refuses to clobber pre-existing non-symlink files
    unless -Force is passed (originals are backed up to .bak-<UTC> first).

.PARAMETER Force
    Replace existing non-symlink files. The original is renamed to
    "<path>.bak-<UTC-timestamp>" before the symlink is created.

.PARAMETER Uninstall
    Remove only the links this script created (links whose target points
    into this repository). All other files under ~/.claude, ~/.codex,
    ~/.gemini are left untouched.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host '[info]' -ForegroundColor Blue   -NoNewline; Write-Host (' ' + ($Message -join ' '))
}
function Write-Ok   { param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host '[ ok ]' -ForegroundColor Green  -NoNewline; Write-Host (' ' + ($Message -join ' '))
}
function Write-Warn { param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host '[warn]' -ForegroundColor Yellow -NoNewline; Write-Host (' ' + ($Message -join ' '))
}
function Write-Err  { param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-Host '[err ]' -ForegroundColor Red    -NoNewline; Write-Host (' ' + ($Message -join ' '))
}

function Resolve-RepoDir {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    return (Get-Item -LiteralPath $scriptPath).Directory.FullName
}

function Test-RepoLocked {
    param([Parameter(Mandatory)][string]$RepoDir)
    $probe = Join-Path -Path $RepoDir -ChildPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $probe)) { return $false }
    $bytes = Get-Content -LiteralPath $probe -Encoding Byte -TotalCount 10 -ErrorAction SilentlyContinue
    if (-not $bytes -or $bytes.Length -lt 10) { return $false }
    # git-crypt magic: 0x00 G I T C R Y P T 0x00
    $magic = @(0, 71, 73, 84, 67, 82, 89, 80, 84, 0)
    for ($i = 0; $i -lt 10; $i++) {
        if ($bytes[$i] -ne $magic[$i]) { return $false }
    }
    return $true
}

function Test-SymlinkSupport {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }

    $devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    try {
        $val = (Get-ItemProperty -Path $devKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
        if ($val -eq 1) { return $true }
    }
    catch {
        # Key or value absent — Developer Mode is off.
    }
    return $false
}

# Mapping: repo-relative source -> %USERPROFILE%-relative link.
$Links = @(
    @{ Source = 'AGENTS.md';     Link = '.claude\CLAUDE.md'     },
    @{ Source = 'agents';        Link = '.claude\agents'        },
    @{ Source = 'commands';      Link = '.claude\commands'      },
    @{ Source = 'hooks';         Link = '.claude\hooks'         },
    @{ Source = 'settings.json'; Link = '.claude\settings.json' },
    @{ Source = 'skills';        Link = '.claude\skills'        },
    @{ Source = 'AGENTS.md';     Link = '.codex\AGENTS.md'      },
    @{ Source = 'AGENTS.md';     Link = '.gemini\GEMINI.md'     }
)

function Get-BackupPath {
    param([Parameter(Mandatory)][string]$Path)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    return "$Path.bak-$ts"
}

function Get-SymlinkTarget {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    # In PS 5.1, .Target may be a string[]; in PS 7+, typically a string. Normalize.
    $t = $Item.Target
    if ($null -eq $t) { return $null }
    if ($t -is [System.Array]) { return [string]$t[0] }
    return [string]$t
}

function Install-Link {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$LinkRel
    )

    $src = Join-Path -Path $RepoDir         -ChildPath $Source
    $dst = Join-Path -Path $env:USERPROFILE -ChildPath $LinkRel

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warn "skip: source missing in repo ($Source)"
        return $true
    }

    $existing = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.LinkType -eq 'SymbolicLink') {
            $target = Get-SymlinkTarget -Item $existing
            if ($target -eq $src) {
                Write-Ok "exists: $LinkRel"
                return $true
            }
            Write-Warn "replacing stale symlink: $LinkRel -> $target"
            Remove-Item -LiteralPath $dst -Force
        }
        else {
            if ($Force) {
                $backup = Get-BackupPath -Path $dst
                Write-Warn "backing up: $dst -> $backup"
                Move-Item -LiteralPath $dst -Destination $backup
            }
            else {
                Write-Err "would clobber non-symlink: $dst (re-run with -Force to back up + replace)"
                return $false
            }
        }
    }

    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null
    Write-Ok "linked: $LinkRel -> $src"
    return $true
}

function Uninstall-Link {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$LinkRel
    )

    $src = Join-Path -Path $RepoDir         -ChildPath $Source
    $dst = Join-Path -Path $env:USERPROFILE -ChildPath $LinkRel

    $existing = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Info "absent: $LinkRel"
        return
    }
    if ($existing.LinkType -ne 'SymbolicLink') {
        Write-Warn "not a symlink, leaving alone: $LinkRel"
        return
    }

    $target = Get-SymlinkTarget -Item $existing
    if ($target -ne $src) {
        Write-Warn "symlink points elsewhere, leaving alone: $LinkRel -> $target"
        return
    }

    Remove-Item -LiteralPath $dst -Force
    Write-Ok "removed: $LinkRel"
}

try {
    if (-not (Test-SymlinkSupport)) {
        Write-Err 'Cannot create symbolic links from this PowerShell session.'
        Write-Err 'Either enable Developer Mode (Settings -> Privacy & security -> For developers -> Developer Mode = On)'
        Write-Err 'or re-run this script from an elevated PowerShell (Run as Administrator).'
        exit 1
    }

    $RepoDir = Resolve-RepoDir
    Write-Info "repo: $RepoDir"
    Write-Info "home: $env:USERPROFILE"

    if (-not $Uninstall -and (Test-RepoLocked -RepoDir $RepoDir)) {
        $keysrc = Join-Path -Path $RepoDir -ChildPath 'secrets.yaml'
        Write-Err 'repo is git-crypt locked — refusing to symlink encrypted blobs.'
        Write-Err 'Install sops + git-crypt + age, ensure SOPS_AGE_KEY_FILE points at your age key, then:'
        Write-Err "    sops --decrypt --extract '[\""git_crypt_key\""]' `"$keysrc`" | <base64-decode> > `"$env:TEMP\agents-gc.key`""
        Write-Err "    Push-Location `"$RepoDir`"; git-crypt unlock `"$env:TEMP\agents-gc.key`"; Pop-Location"
        Write-Err "    Remove-Item `"$env:TEMP\agents-gc.key`""
        exit 1
    }

    if ($Uninstall) {
        foreach ($entry in $Links) {
            Uninstall-Link -RepoDir $RepoDir -Source $entry.Source -LinkRel $entry.Link
        }
        Write-Ok 'uninstall complete.'
    }
    else {
        $blocked = $false
        foreach ($entry in $Links) {
            if (-not (Install-Link -RepoDir $RepoDir -Source $entry.Source -LinkRel $entry.Link)) {
                $blocked = $true
            }
        }
        if ($blocked) {
            Write-Err 'one or more links could not be created; re-run with -Force to overwrite (existing files will be backed up).'
            exit 1
        }
        Write-Ok 'install complete.'
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
