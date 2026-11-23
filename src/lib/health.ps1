#Requires -Version 5.1
# FFTI — запуск/остановка, состояние, проверки, замеры, обновление пула.

function Get-FftiProcess {
    $p = Get-FftiPaths
    if (-not (Test-Path -LiteralPath $p.PidFile)) { return $null }
    $raw = (Get-Content -LiteralPath $p.PidFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { return $null }
    $procId = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$procId)) { return $null }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 'sing-box') { return $proc }
    return $null
}

function Test-FftiPort {
    param([int]$Port)
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    [bool]$c
}

function Start-Ffti {
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $running = Get-FftiProcess
    if ($running) { return "Уже запущено (pid $($running.Id)). Сначала ffti.ps1 off." }
    if (-not (Test-Path -LiteralPath $p.LogDir)) { New-Item -ItemType Directory -Path $p.LogDir -Force | Out-Null }

    if ([bool]$s['tunnel']['enabled'] -and [string]$s['tunnel']['network'] -eq 'tun' -and -not (Test-FftiAdmin)) {
        throw 'Туннель в режиме TUN требует прав администратора. Запусти от админа (или ВКЛЮЧИТЬ.bat).'
    }

    $autoHours = 0
    if ($s['lists']['autoRefreshHours']) { $autoHours = [int]$s['lists']['autoRefreshHours'] }
    if ($autoHours -gt 0) {
        $stampFile = Join-Path $p.LogDir 'pool-updated.txt'
        $need = $true
        if (Test-Path -LiteralPath $stampFile) {
            $last = Get-Item -LiteralPath $stampFile
            if (((Get-Date) - $last.LastWriteTime).TotalHours -lt $autoHours) { $need = $false }
        }
        if ($need) {
            Write-FftiLog 'auto-refresh pool'
            Update-FftiProxyPool | Out-Null
        }
    }

    $cfg = Write-FftiConfig
    $check = Test-FftiConfig -Path $cfg
    if (-not $check.Ok) { throw ("Конфиг не принят sing-box:`n" + $check.Output) }

    $sb = Get-FftiSingBox
    $out = Join-Path $p.LogDir 'sing-box.out.log'
    $err = Join-Path $p.LogDir 'sing-box.err.log'
    $proc = Start-Process -FilePath $sb -ArgumentList @('run', '-c', $cfg) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $proc.Id | Set-Content -LiteralPath $p.PidFile -Encoding ASCII
    Start-Sleep -Milliseconds 1200
    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $alive) { throw ("sing-box упал сразу. Лог: $err" + [Environment]::NewLine + (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)) }

    $lines = @()
    $lines += "Туннель: pid $($proc.Id), режим $($s['mode']), TUN=$([bool]$s['tunnel']['enabled'])"
    $lines += "Локально: http 127.0.0.1:$($s['tunnel']['localHttpPort']), socks 127.0.0.1:$($s['tunnel']['localSocksPort'])"
    if ([bool]$s['dpi']['enabled']) { $lines += (Start-FftiDpi) } else { $lines += 'DPI: выключен' }
    Write-FftiLog ("start pid=" + $proc.Id + " mode=" + $s['mode'])
    $lines -join [Environment]::NewLine
}

function Stop-Ffti {
    $p = Get-FftiPaths
    $proc = Get-FftiProcess
    $msg = @()
    if ($proc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $msg += "sing-box остановлен (pid $($proc.Id))"
    } else { $msg += 'sing-box не запущен' }
    Remove-Item -LiteralPath $p.PidFile -Force -ErrorAction SilentlyContinue
    $msg += (Stop-FftiDpi)
    Write-FftiLog 'stop'
    $msg -join [Environment]::NewLine
}

function Show-FftiStatus {
    $s = Get-FftiSettings
    $p = Get-FftiPaths
    $proc = Get-FftiProcess
    $proxies = @(Get-FftiProxies)
    $dpiProc = @(Get-FftiDpiProcess)
    $rows = @()
    $rows += "режим:        $($s['mode'])"
    $rows += "туннель:      $(if ($s['tunnel']['enabled']) { 'включён' } else { 'выключен' }) / $($s['tunnel']['network'])"
    $rows += "sing-box:     $(if ($proc) { "работает, pid $($proc.Id)" } else { 'остановлен' })"
    $rows += "прокси в пуле: $($proxies.Count)"
    $rows += "http-порт:    $($s['tunnel']['localHttpPort']) $(if (Test-FftiPort ([int]$s['tunnel']['localHttpPort'])) { 'слушает' } else { 'закрыт' })"
    $rows += "socks-порт:   $($s['tunnel']['localSocksPort']) $(if (Test-FftiPort ([int]$s['tunnel']['localSocksPort'])) { 'слушает' } else { 'закрыт' })"
    $rows += "DPI (winws):  $(if ($dpiProc.Count) { "работает, pid $($dpiProc[0].ProcessId), профиль $($s['dpi']['profile'])" } else { 'остановлен' })"
    $rows += "запросов:     DNS $($s['dns']['mode']), sniff $([bool]$s['performance']['sniff']), RU напрямую $([bool]$s['tunnel']['ruBypass'])"
    $rows -join [Environment]::NewLine
}

function Test-FftiCurl {
    param([string]$Url, [string]$Proxy, [int]$TimeoutSec = 15)
    $curlArgs = @('-s', '-o', 'NUL', '-w', '%{http_code} %{time_total}', '--max-time', "$TimeoutSec")
    if ($Proxy) { $curlArgs += @('-x', $Proxy) }
    else { $curlArgs += @('--noproxy', '*') }
    $curlArgs += $Url
    $res = & curl.exe @curlArgs 2>&1
    $txt = ($res -join ' ').Trim()
    if ($txt -match '^(\d{3}) (\d+[\.,]\d+)$') {
        $code = [int]$Matches[1]
        $sec = [double]($Matches[2] -replace ',', '.')
        [pscustomobject]@{ Code = $code; Ms = [int]($sec * 1000); Err = '' }
    } else {
        [pscustomobject]@{ Code = 0; Ms = 0; Err = $txt }
    }
}

function Invoke-FftiTest {
    param([string[]]$Hosts)
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    if (-not $Hosts -or $Hosts.Count -eq 0) {
        $Hosts = @('ya.ru', 'vk.com', 'mail.ru', 'discord.com', 'chatgpt.com', 'spotify.com', 'instagram.com', 'roblox.com')
    }
    $httpPort = 1181
    $socksPort = 1180
    $cfgObj = New-FftiConfig -ProxyOnly
    foreach ($inb in $cfgObj['inbounds']) {
        if ($inb['type'] -eq 'http') { $inb['listen_port'] = $httpPort }
        if ($inb['type'] -eq 'socks') { $inb['listen_port'] = $socksPort }
    }
    $tmp = Join-Path $p.LogDir 'config.test.json'
    Write-FftiText -Path $tmp -Text ($cfgObj | ConvertTo-Json -Depth 20)
    $check = Test-FftiConfig -Path $tmp
    if (-not $check.Ok) { throw ("Тестовый конфиг не принят:`n" + $check.Output) }

    $sb = Get-FftiSingBox
    $err = Join-Path $p.LogDir 'test-sing-box.err.log'
    $out = Join-Path $p.LogDir 'test-sing-box.out.log'
    $proc = Start-Process -FilePath $sb -ArgumentList @('run', '-c', $tmp) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    Start-Sleep -Milliseconds 1500
    $proxyUrl = "socks5h://127.0.0.1:$socksPort"
    $results = @()
    try {
        foreach ($h in $Hosts) {
            $url = "https://$h"
            $direct = Test-FftiCurl -Url $url -TimeoutSec 12
            $viaFfti = Test-FftiCurl -Url $url -Proxy $proxyUrl -TimeoutSec 20
            $route = 'напрямую'
            if (@(Read-FftiList $s['lists']['proxyDomains']) -contains $h) { $route = 'через туннель' }
            $results += [pscustomobject]@{
                host   = $h
                маршрут = $route
                прямой = $(if ($direct.Code) { "$($direct.Code) / $($direct.Ms) мс" } else { 'нет' })
                ffti   = $(if ($viaFfti.Code) { "$($viaFfti.Code) / $($viaFfti.Ms) мс" } else { 'нет' })
            }
        }
    } finally {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $json = Join-Path $p.LogDir "test-$stamp.json"
    ($results | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $json -Encoding UTF8
    $results | Format-Table -AutoSize
    ''
    "Результат сохранён: $json"
}

function Update-FftiProxyPool {
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $cands = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @(Read-FftiList $s['lists']['proxies'])) { if ($l -match '^\S+:\d+$') { $cands.Add($l) } }
    $srcFile = Join-Path $p.ListsDir 'proxy-sources.txt'
    if (Test-Path -LiteralPath $srcFile) {
        foreach ($u in @(Read-FftiList 'lists/proxy-sources.txt')) {
            if ($u -notmatch '^https?://') { continue }
            $raw = & curl.exe -s --max-time 25 $u 2>$null
            foreach ($line in @($raw)) {
                foreach ($m in [regex]::Matches([string]$line, '\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b')) { $cands.Add($m.Value) }
            }
        }
    }
    $uniq = @($cands | Select-Object -Unique)
    if ($uniq.Count -eq 0) { return 'Нет кандидатов: добавь адреса в lists\proxies.txt или ссылки в lists\proxy-sources.txt' }
    $alive = @()
    $limit = [Math]::Min($uniq.Count, 60)
    foreach ($c in $uniq[0..($limit - 1)]) {
        $parts = $c.Split(':')
        $hostName = $parts[0]; $port = [int]$parts[1]
        if (-not (Test-NetConnection -ComputerName $hostName -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue)) { continue }
        $probe = Test-FftiCurl -Url 'https://discord.com' -Proxy "socks5h://$c" -TimeoutSec 10
        if ($probe.Code -eq 200) { $alive += [pscustomobject]@{ Addr = $c; Ms = $probe.Ms } }
    }
    $alive = @($alive | Sort-Object Ms)
    if ($alive.Count -eq 0) {
        "Живых прокси не найдено из $limit проверенных. Пул не изменён."
        return
    }
    $top = @($alive | Select-Object -First 12)
    $header = @(
        '# SOCKS5-прокси пула. Формат: host:port',
        '# Строки с # игнорируются. Первый живой по замеру (urltest) и станет туннелем.',
        ('# обновлено: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    )
    ($header + ($top | ForEach-Object { $_.Addr })) | Set-Content -LiteralPath (Join-Path $p.Root 'lists\proxies.txt') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p.LogDir 'pool-updated.txt') -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII
    $top | Select-Object Addr, @{n = 'замер'; e = { "$($_.Ms) мс" } } | Format-Table -AutoSize
    "Записано $($top.Count) прокси в lists\proxies.txt"
}

function Set-FftiMode {
    param([string]$Name)
    $p = Get-FftiPaths
    $modes = Read-FftiJson (Join-Path $p.SettingsDir 'modes.json')
    if (-not $Name) { return ('Доступные режимы: ' + (@($modes['modes'].Keys) -join ', ')) }
    if (-not $modes['modes'].Contains($Name)) { return "Нет режима '$Name'. Есть: $(@($modes['modes'].Keys) -join ', ')" }
    Set-FftiSetting -KeyPath 'mode' -Value $Name | Out-Null
    $note = $modes['modes'][$Name]['note']
    "Режим: $Name — $note" + [Environment]::NewLine + 'Применится после ffti.ps1 restart'
}

function Show-FftiDoctor {
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $rows = @()
    $ok = $true

    try { $sb = Get-FftiSingBox; $ver = (& $sb version | Select-Object -First 1); $rows += "OK   sing-box: $ver" }
    catch { $ok = $false; $rows += "FAIL sing-box: $($_.Exception.Message)" }

    $cfg = Write-FftiConfig
    $check = Test-FftiConfig -Path $cfg
    if ($check.Ok) { $rows += 'OK   конфиг: анализатор sing-box не нашёл ошибок' } else { $ok = $false; $rows += "FAIL конфиг: $($check.Output)" }

    $proxies = @(Get-FftiProxies)
    if ($proxies.Count -gt 0) { $rows += "OK   пул: $($proxies.Count) адрес(ов)" } else { $ok = $false; $rows += 'FAIL пул: lists\proxies.txt пуст' }

    $admin = Test-FftiAdmin
    if ($admin) { $rows += 'OK   права: администратор' } else { $rows += 'WARN права: без админа TUN и DPI не поднять' }

    try {
        $spec = Get-FftiDpiArgs
        if (Test-Path -LiteralPath $spec.Exe) { $rows += "OK   DPI: winws найден ($($spec.Dir))" } else { $rows += 'WARN DPI: winws.exe не найден' }
    } catch { $rows += "WARN DPI: $($_.Exception.Message)" }

    if ((Get-FftiDpiProcess)) { $rows += 'WARN DPI: winws уже запущен (служба zapret?) — два desync-движка конфликтуют' }
    $zapretSvc = Get-Service zapret -ErrorAction SilentlyContinue
    if ($zapretSvc -and $zapretSvc.Status -eq 'Running') { $rows += 'WARN служба zapret запущена — выключи её перед FFTI' }

    $sbProcs = @(Get-Process sing-box -ErrorAction SilentlyContinue)
    if ($sbProcs.Count -gt 1) { $rows += "WARN процессов sing-box: $($sbProcs.Count) (лишние стоит погасить)" }

    $dns = Test-FftiCurl -Url 'https://ya.ru' -TimeoutSec 10
    if ($dns.Code -ge 200 -and $dns.Code -lt 400) { $rows += "OK   RU-сайты без туннеля: $($dns.Code) / $($dns.Ms) мс" } else { $rows += 'WARN RU-сайты без туннеля не открылись' }

    if (Test-FftiPort ([int]$s['tunnel']['localHttpPort'])) { $rows += "WARN порт $($s['tunnel']['localHttpPort']) занят — смени tunnel.localHttpPort" }
    if (Test-FftiPort ([int]$s['tunnel']['localSocksPort'])) { $rows += "WARN порт $($s['tunnel']['localSocksPort']) занят — смени tunnel.localSocksPort" }

    $rows -join [Environment]::NewLine
}
