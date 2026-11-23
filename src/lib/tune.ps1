#Requires -Version 5.1
# FFTI — системные настройки под скорость (по желанию): сеть, игры, приоритеты.
# Применение: ffti.bat tune on    Откат: ffti.bat tune off

$ErrorActionPreference = 'Stop'

function Get-FftiTuneBackupPath {
    $p = Get-FftiPaths
    Join-Path $p.LogDir 'tune-backup.json'
}

function Set-FftiRegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    [pscustomobject]@{ Path = $Path; Name = $Name; Old = $current; New = $Value; Type = $Type }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Invoke-FftiTune {
    param([switch]$Revert)
    if (-not (Test-FftiAdmin)) { throw 'Для тюнинга нужны права администратора.' }
    $p = Get-FftiPaths
    if (-not (Test-Path -LiteralPath $p.LogDir)) { New-Item -ItemType Directory -Path $p.LogDir -Force | Out-Null }
    $backupPath = Get-FftiTuneBackupPath

    if ($Revert) {
        if (-not (Test-Path -LiteralPath $backupPath)) { return 'Нечего откатывать: нет logs\tune-backup.json' }
        $items = @(Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json)
        foreach ($it in $items) {
            if ($null -eq $it.Old -or $it.Old -eq '') {
                Remove-ItemProperty -Path $it.Path -Name $it.Name -ErrorAction SilentlyContinue
            } else {
                New-ItemProperty -Path $it.Path -Name $it.Name -Value $it.Old -PropertyType $it.Type -Force | Out-Null
            }
        }
        Remove-Item -LiteralPath $backupPath -Force
        Write-FftiLog 'tune revert'
        return 'Системные настройки возвращены как было.'
    }

    $changes = @()
    $ifaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' | Where-Object {
        $null -ne (Get-ItemProperty -Path $_.PSPath -Name 'DhcpIPAddress' -ErrorAction SilentlyContinue) -or
        $null -ne (Get-ItemProperty -Path $_.PSPath -Name 'IPAddress' -ErrorAction SilentlyContinue)
    }
    foreach ($i in $ifaces) {
        $changes += Set-FftiRegValue -Path $i.PSPath -Name 'TcpAckFrequency' -Value 1
        $changes += Set-FftiRegValue -Path $i.PSPath -Name 'TCPNoDelay' -Value 1
        $changes += Set-FftiRegValue -Path $i.PSPath -Name 'TcpDelAckTicks' -Value 0
    }

    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $changes += Set-FftiRegValue -Path $mm -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF
    $changes += Set-FftiRegValue -Path $mm -Name 'SystemResponsiveness' -Value 0
    $game = Join-Path $mm 'Tasks\Games'
    if (Test-Path -LiteralPath $game) {
        $changes += Set-FftiRegValue -Path $game -Name 'GPU Priority' -Value 8
        $changes += Set-FftiRegValue -Path $game -Name 'Priority' -Value 6
        $changes += Set-FftiRegValue -Path $game -Name 'Scheduling Category' -Value 'High' -Type 'String'
        $changes += Set-FftiRegValue -Path $game -Name 'SFIO Priority' -Value 'High' -Type 'String'
    }

    & powercfg /setactive SCHEME_MIN 2>$null
    $changes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-FftiLog "tune apply: $($changes.Count) значений"
    @(
        "Применено изменений: $($changes.Count)",
        'Сеть: мгновенные ACK и без задержки Нагла.',
        'Игры: Multimedia-класс без троттлинга сети, высокий приоритет задач.',
        'Питание: схема «Максимальная производительность».',
        'Откат: ffti.bat tune off. Полный эффект — после перезагрузки.'
    ) -join [Environment]::NewLine
}
