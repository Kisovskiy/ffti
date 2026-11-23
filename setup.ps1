#Requires -Version 5.1
# FFTI — подготовка: скачать sing-box в bin\, проверить окружение.
param(
    [string]$SingBoxVersion = '1.14.4',
    [string]$ZapretDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'
foreach ($d in @($bin, (Join-Path $root 'logs'), (Join-Path $root 'rules'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$exe = Join-Path $bin 'sing-box.exe'
if (Test-Path -LiteralPath $exe) {
    "sing-box уже на месте: $exe"
} else {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
    $name = "sing-box-$SingBoxVersion-windows-$arch"
    $zip = Join-Path $env:TEMP "$name.zip"
    $url = "https://github.com/SagerNet/sing-box/releases/download/v$SingBoxVersion/$name.zip"
    "Скачивание: $url"
    & curl.exe -L --fail --max-time 180 -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось скачать sing-box. Проверь сеть или положи bin\sing-box.exe вручную.' }
    $tmp = Join-Path $env:TEMP $name
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
    if (-not $found) { throw 'В архиве нет sing-box.exe' }
    Copy-Item -LiteralPath $found.FullName -Destination $exe -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    "Готово: $exe"
}

# Набор российских подсетей: нужен, чтобы RU-трафик не заходил в туннель вообще.
$srs = Join-Path $root 'rules\geoip-ru.srs'
if (-not (Test-Path -LiteralPath $srs)) {
    $url = 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs'
    "Скачивание списка российских подсетей..."
    & curl.exe -L --fail --max-time 60 -o $srs $url 2>$null
    if (Test-Path -LiteralPath $srs) { "Готово: rules\geoip-ru.srs" } else { 'Список РФ не скачался — RU-трафик пойдёт через туннель напрямую (медленнее, но работает).' }
} else { 'Список российских подсетей уже на месте.' }

# DPI-движок (winws из zapret): берём уже установленный, если есть
$cands = @()
if ($ZapretDir) { $cands += $ZapretDir }
$cands += @('C:\Users\hujab\Apps\Obhod\zapret', (Join-Path $root 'zapret'), 'C:\zapret')
$foundDir = $null
foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'bin\winws.exe'))) { $foundDir = $c; break } }
if ($foundDir) {
    "DPI-движок найден: $foundDir"
    . (Join-Path $root 'src\lib\common.ps1')
    Set-FftiSetting -KeyPath 'dpi.zapretDir' -Value $foundDir | Out-Null
} else {
    'DPI-движок не найден. Скачай zapret и укажи путь: ffti.bat set dpi.zapretDir "C:\zapret"'
}

"Проверка: ffti.bat doctor"
