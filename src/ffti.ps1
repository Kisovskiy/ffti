#Requires -Version 5.1
# FFTI — командный интерфейс: on / off / status / test / doctor / mode / set / refresh

param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]$Rest
)

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'common.ps1')
. (Join-Path $libDir 'config.ps1')
. (Join-Path $libDir 'dpi.ps1')
. (Join-Path $libDir 'health.ps1')
. (Join-Path $libDir 'tune.ps1')

switch ($Command.ToLower()) {
    'on' { Start-Ffti }
    'off' { Stop-Ffti }
    'restart' { Stop-Ffti | Out-Null; Start-Sleep -Milliseconds 500; Start-Ffti }
    'status' { Show-FftiStatus }
    'test' { Invoke-FftiTest -Hosts $Rest }
    'doctor' { Show-FftiDoctor }
    'refresh' { Update-FftiProxyPool }
    'mode' { Set-FftiMode -Name ([string]($Rest | Select-Object -First 1)) }
    'set' {
        if (-not $Rest -or $Rest.Count -lt 2) { 'нужно: set <ключ> <значение>' } else { Set-FftiSetting -KeyPath $Rest[0] -Value $Rest[1] }
    }
    'config' { Write-FftiConfig }
    'check' { (Test-FftiConfig).Output }
    'dpi' {
        $what = [string]($Rest | Select-Object -First 1)
        if ($what -eq 'on') { Start-FftiDpi }
        elseif ($what -eq 'off') { Stop-FftiDpi }
        else { $r = Test-FftiDpiArgv; if ($r.Ok) { "Аргументы DPI записаны: $($r.Log)" } else { "Нет файлов: $($r.Missing -join ', ')" } }
    }
    'tune' {
        $what = [string]($Rest | Select-Object -First 1)
        if ($what -eq 'off') { Invoke-FftiTune -Revert } else { Invoke-FftiTune }
    }
    default {
        @'
FFTI — Freedom For The Internet

  on                    поднять туннель + DPI (по настройкам)
  off                   выключить всё
  restart               перезапустить
  status                состояние: режим, прокси, процессы, порты
  test [host ...]       замер: что напрямую, что через туннель, за сколько
  doctor                проверка окружения и типовых проблем
  refresh               обновить пул прокси и замерить
  mode <web|game|max|roblox>   переключить режим
  set <ключ> <значение> настройка, например: set dpi.enabled true
  dpi [on|off|args]     слой обхода DPI (winws): вкл / выкл / показать аргументы
  tune [on|off]         системные настройки под скорость (сеть, игры, питание)
  config                собрать config.generated.json
  check                 проверить конфиг анализатором sing-box
'@
    }
}
