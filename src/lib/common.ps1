#Requires -Version 5.1
# FFTI — общие функции: путь, настройки, лог, бинарники.
$ErrorActionPreference = 'Stop'

function Write-FftiText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-FftiRoot {
    param([string]$Start)
    if (-not $Start) { $Start = $PSScriptRoot }
    $dir = Get-Item -LiteralPath $Start
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'settings\default.json')) { return $dir.FullName }
        $dir = $dir.Parent
    }
    throw 'Не найден корень FFTI: рядом нет settings\default.json.'
}

function Get-FftiPaths {
    $root = Get-FftiRoot
    [pscustomobject]@{
        Root        = $root
        SettingsDir = Join-Path $root 'settings'
        ListsDir    = Join-Path $root 'lists'
        BinDir      = Join-Path $root 'bin'
        LogDir      = Join-Path $root 'logs'
        RulesDir    = Join-Path $root 'rules'
        ConfigFile  = Join-Path $root 'config.generated.json'
        UserFile    = Join-Path $root 'settings\user.json'
        StateFile   = Join-Path $root 'logs\state.json'
        PidFile     = Join-Path $root 'logs\sing-box.pid'
    }
}

function ConvertTo-FftiHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $out[$k] = ConvertTo-FftiHashtable $InputObject[$k] }
        return $out
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-FftiHashtable $p.Value }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $arr = @()
        foreach ($i in $InputObject) { $arr += ,(ConvertTo-FftiHashtable $i) }
        return $arr
    }
    return $InputObject
}

function Merge-FftiDeep {
    param($Base, $Overlay)
    if ($null -eq $Overlay) { return $Base }
    if ($null -eq $Base) { return $Overlay }
    if (-not ($Base -is [System.Collections.IDictionary]) -or -not ($Overlay -is [System.Collections.IDictionary])) { return $Overlay }
    foreach ($k in $Overlay.Keys) {
        if ($Base.Contains($k) -and ($Base[$k] -is [System.Collections.IDictionary]) -and ($Overlay[$k] -is [System.Collections.IDictionary])) {
            $null = Merge-FftiDeep $Base[$k] $Overlay[$k]
        } else {
            $Base[$k] = $Overlay[$k]
        }
    }
    return $Base
}

function Read-FftiJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return $null }
    ConvertTo-FftiHashtable ($raw | ConvertFrom-Json)
}

function Get-FftiSettings {
    $p = Get-FftiPaths
    $base = Read-FftiJson (Join-Path $p.SettingsDir 'default.json')
    $user = Read-FftiJson $p.UserFile
    if ($user) { $base = Merge-FftiDeep $base $user }
    $modes = Read-FftiJson (Join-Path $p.SettingsDir 'modes.json')
    $modeName = [string]$base['mode']
    if ($modes -and $modes['modes'] -and $modes['modes'].Contains($modeName)) {
        $base = Merge-FftiDeep $base $modes['modes'][$modeName]['patch']
    }
    $base
}

function Set-FftiSetting {
    param([string]$KeyPath, [string]$Value)
    $p = Get-FftiPaths
    $user = Read-FftiJson $p.UserFile
    if (-not $user) { $user = [ordered]@{} }
    $parts = $KeyPath.Split('.')
    $node = $user
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $key = $parts[$i]
        if (-not $node.Contains($key) -or -not ($node[$key] -is [System.Collections.IDictionary])) { $node[$key] = [ordered]@{} }
        $node = $node[$key]
    }
    $leaf = $parts[$parts.Length - 1]
    $parsed = $Value
    if ($Value -match '^(true|false)$') { $parsed = [bool]::Parse($Value) }
    elseif ($Value -match '^-?\d+$') { $parsed = [int]$Value }
    elseif ($Value -match '^-?\d+\.\d+$') { $parsed = [double]$Value }
    $node[$leaf] = $parsed
    Write-FftiText -Path $p.UserFile -Text ($user | ConvertTo-Json -Depth 20)
    "записано: $KeyPath = $parsed"
}

function Write-FftiLog {
    param([string]$Message, [string]$Name = 'ffti.log')
    $p = Get-FftiPaths
    if (-not (Test-Path -LiteralPath $p.LogDir)) { New-Item -ItemType Directory -Path $p.LogDir -Force | Out-Null }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $p.LogDir $Name) -Value $line -Encoding UTF8
}

function Test-FftiAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FftiSingBox {
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $cands = @()
    if ($s['tunnel'] -and $s['tunnel']['singBoxPath']) { $cands += [string]$s['tunnel']['singBoxPath'] }
    $cands += (Join-Path $p.BinDir 'sing-box.exe')
    $cands += 'C:\Users\hujab\Apps\Obhod\proxy\sing-box.exe'
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command sing-box -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'sing-box.exe не найден. Положи его в bin\ или укажи tunnel.singBoxPath.'
}

function Read-FftiList {
    param([string]$RelativePath)
    $p = Get-FftiPaths
    $full = Join-Path $p.Root $RelativePath
    if (-not (Test-Path -LiteralPath $full)) { return @() }
    Get-Content -LiteralPath $full -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Get-FftiProxies {
    $s = Get-FftiSettings
    $lines = Read-FftiList $s['lists']['proxies']
    $out = @()
    $i = 0
    foreach ($l in $lines) {
        if ($l -match '^\[?([0-9a-fA-F\.\:]+)\]?:(\d{2,5})$') { $hostPart = $Matches[1]; $port = [int]$Matches[2] } else { continue }
        $i++
        $out += [pscustomobject]@{ Tag = ("p$i"); Host = $hostPart; Port = $port }
    }
    $out
}
