#Requires -Version 5.1
# FFTI — слой обхода DPI (winws, как в zapret): подмена/фрагментация первого пакета.
# Используем только то, что реально работает у zapret: fake TLS, multidisorder, QUIC fake.

function Get-FftiDpiArgs {
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $dpi = $s['dpi']
    $dir = [string]$dpi['zapretDir']
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        foreach ($c in @('C:\Users\hujab\Apps\Obhod\zapret', (Join-Path $p.Root 'zapret'), 'C:\zapret')) {
            if ($c -and (Test-Path -LiteralPath $c)) { $dir = $c; break }
        }
    }
    if (-not $dir) { throw 'Папка zapret не найдена: укажи dpi.zapretDir (в ней bin\winws.exe).' }
    $bin = Join-Path $dir 'bin'
    $lists = Join-Path $dir 'lists'
    $winws = Join-Path $bin 'winws.exe'
    if (-not (Test-Path -LiteralPath $winws)) { throw "Нет winws.exe: $winws" }

    $repeats = [int]$dpi['repeats']
    if ($repeats -le 0) { $repeats = 11 }
    $fakeTls = [string]$dpi['fakeTls']; if (-not $fakeTls) { $fakeTls = Join-Path $bin 'tls_clienthello_www_google_com.bin' }
    $fakeQuic = [string]$dpi['fakeQuic']; if (-not $fakeQuic) { $fakeQuic = Join-Path $bin 'quic_initial_www_google_com.bin' }
    $listGeneral = Join-Path $lists 'list-general.txt'
    $listGoogle = Join-Path $lists 'list-google.txt'
    $listDiscord = Join-Path $lists 'list-general.txt'
    $ipsetAll = Join-Path $lists 'ipset-all.txt'
    $excludes = @()
    foreach ($e in @('list-exclude.txt', 'list-exclude-user.txt')) {
        $f = Join-Path $lists $e
        if (Test-Path -LiteralPath $f) { $excludes += "--hostlist-exclude=`"$f`"" }
    }
    foreach ($e in @('ipset-exclude.txt', 'ipset-exclude-user.txt')) {
        $f = Join-Path $lists $e
        if (Test-Path -LiteralPath $f) { $excludes += "--ipset-exclude=`"$f`"" }
    }
    $ex = ($excludes -join ' ')

    $profile = [string]$dpi['profile']
    $parts = [System.Collections.Generic.List[string]]::new()

    $tlsFilter = @(
        '--dpi-desync=fake,multidisorder',
        '--dpi-desync-split-pos=1,midsld',
        "--dpi-desync-repeats=$repeats",
        '--dpi-desync-fooling=badseq',
        '--dpi-desync-fake-tls=0x00000000',
        '--dpi-desync-fake-tls=!',
        '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
        '--new'
    ) -join ' '

    $quicFilter = @(
        '--dpi-desync=fake',
        "--dpi-desync-repeats=$repeats",
        "--dpi-desync-fake-quic=`"$fakeQuic`"",
        '--new'
    ) -join ' '

    $wfTcp = '--wf-tcp=80,443,2053,2083,2087,2096,8443'
    $wfUdp = '--wf-udp=443,19294-19344,50000-50100'
    if ($profile -eq 'games' -or $profile -eq 'full') {
        $wfTcp += ',1024-65535'
        $wfUdp += ',1024-65535'
    }

    # DPI работает только на физическом адаптере: пакеты туннеля он ломает.
    $iface = [string]$dpi['iface']
    if (-not $iface) {
        $cur = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wintun|TAP|sing-tun' } |
            Select-Object -First 1
        if ($cur) { $iface = [string]$cur.ifIndex }
    }
    if ($iface) { $wfTcp = "--wf-iface=$iface $wfTcp" }

    $parts.Add($wfTcp)
    $parts.Add($wfUdp)

    if ($profile -in @('google', 'general', 'max', 'full')) {
        if (Test-Path -LiteralPath $listGoogle) {
            $parts.Add("--filter-tcp=443 --hostlist=`"$listGoogle`" --ip-id=zero $tlsFilter")
        }
        $parts.Add("--filter-udp=443 --hostlist=`"$listGeneral`" $quicFilter")
    }
    if ($profile -in @('general', 'max', 'full')) {
        if (Test-Path -LiteralPath $listGeneral) {
            $parts.Add("--filter-tcp=80,443 --hostlist=`"$listGeneral`" $ex $tlsFilter")
            if (Test-Path -LiteralPath $ipsetAll) {
                $parts.Add("--filter-tcp=80,443 --ipset=`"$ipsetAll`" $ex $tlsFilter")
                $parts.Add("--filter-udp=443 --ipset=`"$ipsetAll`" $ex $quicFilter")
            }
        }
    }
    if ($profile -eq 'games' -or $profile -eq 'full') {
        $fakeDiscord = Join-Path $bin 'ACTIVE_DISCORD_UDP.bin'
        if (Test-Path -LiteralPath $fakeDiscord) {
            $parts.Add("--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord=`"$fakeDiscord`" --dpi-desync-fake-stun=`"$fakeDiscord`" --dpi-desync-repeats=6 --new")
        }
        $fakeGame = Join-Path $bin 'ACTIVE_GAME_UDP.bin'
        if (Test-Path -LiteralPath $fakeGame) {
            $parts.Add("--filter-tcp=1024-65535 --dpi-desync=fake,multidisorder --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=$repeats --dpi-desync-fake-unknown=`"$fakeTls`" --new")
            $parts.Add("--filter-udp=1024-65535 --dpi-desync=fake --dpi-desync-repeats=10 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp=`"$fakeGame`" --dpi-desync-cutoff=n2 --new")
        }
        if (Test-Path -LiteralPath $listDiscord) {
            $parts.Add("--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media $tlsFilter")
        }
    }

    [pscustomobject]@{
        Exe  = $winws
        Dir  = $dir
        Args = @($parts)
    }
}

function Get-FftiDpiProcess {
    Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
}

function Start-FftiDpi {
    $s = Get-FftiSettings
    if (-not [bool]$s['dpi']['enabled']) { return 'DPI выключен в настройках: dpi.enabled=false' }
    if (-not (Test-FftiAdmin)) { throw 'Для DPI нужны права администратора (WinDivert).' }
    $existing = Get-FftiDpiProcess
    if ($existing) { return "winws уже запущен (pid $($existing.ProcessId))" }
    $spec = Get-FftiDpiArgs
    $argLine = ($spec.Args -join ' ')
    Write-FftiLog "dpi start: $($spec.Exe) $argLine" 'dpi.log'
    $p = Get-FftiPaths
    $errLog = Join-Path $p.LogDir 'dpi.err.log'
    $outLog = Join-Path $p.LogDir 'dpi.out.log'
    Start-Process -FilePath $spec.Exe -ArgumentList $argLine -WorkingDirectory $spec.Dir -WindowStyle Hidden -RedirectStandardError $errLog -RedirectStandardOutput $outLog
    Start-Sleep -Milliseconds 1200
    $proc = Get-FftiDpiProcess
    if ($proc) { "DPI включён: profile=$($s['dpi']['profile']), pid=$($proc.ProcessId)" }
    else {
        $tail = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
        if ($tail) { $tail = $tail.Trim() } else { $tail = 'вывода нет' }
        "DPI не поднялся. Ответ движка: $tail"
    }
}

function Stop-FftiDpi {
    $procs = @(Get-FftiDpiProcess)
    if (-not $procs) { return 'DPI не запущен' }
    foreach ($pr in $procs) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-FftiLog 'dpi stop' 'dpi.log'
    "DPI выключен ($($procs.Count) процесс(ов))"
}

function Test-FftiDpiArgv {
    $spec = Get-FftiDpiArgs
    $p = Get-FftiPaths
    if (-not (Test-Path -LiteralPath $p.LogDir)) { New-Item -ItemType Directory -Path $p.LogDir -Force | Out-Null }
    $out = Join-Path $p.LogDir 'dpi-argv.txt'
    @("exe: $($spec.Exe)", "dir: $($spec.Dir)", '') + ($spec.Args | ForEach-Object { $_ + ' ^' }) |
        Set-Content -LiteralPath $out -Encoding UTF8
    $missing = @()
    if (-not (Test-Path -LiteralPath $spec.Exe)) { $missing += $spec.Exe }
    [pscustomobject]@{ Ok = ($missing.Count -eq 0); Log = $out; Missing = $missing }
}
