#Requires -Version 5.1
# FFTI — сборка конфигурации sing-box из настроек и списков.

function New-FftiConfig {
    param(
        [switch]$ProxyOnly
    )
    $p = Get-FftiPaths
    $s = Get-FftiSettings
    $t = $s['tunnel']
    $perf = $s['performance']
    $proxyDomains = @(Read-FftiList $s['lists']['proxyDomains'])
    $proxyIps = @(Read-FftiList $s['lists']['proxyIps'])
    $gameDomains = @(Read-FftiList $s['lists']['gamesDomains'])
    $gameIps = @(Read-FftiList $s['lists']['gamesIps'])
    $robloxDomains = @(Read-FftiList $s['lists']['robloxDomains'])
    $proxies = @(Get-FftiProxies)

    if (-not $ProxyOnly -and $t['enabled'] -and $proxies.Count -eq 0) {
        throw 'Пул прокси пуст: lists\proxies.txt без рабочих строк. Запусти ffti.ps1 refresh.'
    }

    # --- DNS ---
    $dnsMode = [string]$s['dns']['mode']
    if ($dnsMode -eq 'split') {
        $dns = [ordered]@{
            servers = @(
                [ordered]@{ tag = 'ru'; type = 'udp'; server = [string]$s['dns']['ru'] },
                [ordered]@{ tag = 'global'; type = 'udp'; server = [string]$s['dns']['global'] }
            )
            rules   = @(
                [ordered]@{ domain_suffix = $proxyDomains; server = 'global' }
            )
            final   = 'ru'
        }
        $resolver = 'ru'
    } else {
        $dns = [ordered]@{
            servers = @([ordered]@{ tag = 'local'; type = 'local' })
            final   = 'local'
        }
        $resolver = 'local'
    }

    # --- входящие ---
    $inbounds = @()
    if (-not $ProxyOnly -and $t['enabled'] -and [string]$t['network'] -eq 'tun') {
        $tun = [ordered]@{
            type        = 'tun'
            tag         = 'tun-in'
            address     = @([string]$t['tunAddress'])
            mtu         = [int]$t['mtu']
            stack       = [string]$t['stack']
            auto_route  = [bool]$t['autoRoute']
            strict_route = [bool]$t['strictRoute']
        }
        if ([bool]$t['ruBypass']) {
            $srs = Join-Path $p.RulesDir 'geoip-ru.srs'
            if (Test-Path -LiteralPath $srs) { $tun['route_exclude_address_set'] = 'geoip-ru' }
        }
        $inbounds += $tun
    }
    $inbounds += [ordered]@{ type = 'http'; tag = 'http-in'; listen = '127.0.0.1'; listen_port = [int]$t['localHttpPort'] }
    $inbounds += [ordered]@{ type = 'socks'; tag = 'socks-in'; listen = '127.0.0.1'; listen_port = [int]$t['localSocksPort'] }

    # --- исходящие ---
    $outbounds = @()
    if ($proxies.Count -gt 0) {
        $tags = @($proxies | ForEach-Object { $_.Tag })
        $outbounds += [ordered]@{
            type      = 'urltest'
            tag       = 'proxy'
            outbounds = $tags
            url       = [string]$perf['urltestUrl']
            interval  = [string]$perf['urltestInterval']
            tolerance = [int]$perf['urltestTolerance']
        }
        foreach ($px in $proxies) {
            $o = [ordered]@{
                type        = 'socks'
                tag         = $px.Tag
                server      = $px.Host
                server_port = $px.Port
                version     = '5'
            }
            if ([bool]$perf['tcpFastOpen']) { $o['tcp_fast_open'] = $true }
            $outbounds += $o
        }
    }
    $outbounds += [ordered]@{ type = 'direct'; tag = 'direct' }

    # --- маршрутизация ---
    $routes = @()
    if ([bool]$perf['sniff']) { $routes += [ordered]@{ action = 'sniff' } }

    if ([bool]$t['lanBypass']) { $routes += [ordered]@{ ip_is_private = $true; outbound = 'direct' } }

    # Roblox assist: веб-часть в туннель, игровая — нет
    $assist = [bool]$s['games']['robloxAssist']
    $robloxViaProxy = @()
    if ($assist -and $robloxDomains.Count -gt 0) { $robloxViaProxy = $robloxDomains }

    $allProxyDomains = @($proxyDomains + $robloxViaProxy)
    if ($allProxyDomains.Count -gt 0) { $routes += [ordered]@{ domain_suffix = $allProxyDomains; outbound = 'proxy' } }
    if ($proxyIps.Count -gt 0) { $routes += [ordered]@{ ip_cidr = $proxyIps; outbound = 'proxy' } }

    if ([bool]$s['games']['keepGameTrafficDirect']) {
        if ($gameIps.Count -gt 0) { $routes += [ordered]@{ ip_cidr = $gameIps; outbound = 'direct' } }
        $gameDirectDomains = @($gameDomains + $robloxDomains)
        if ($gameDirectDomains.Count -gt 0) { $routes += [ordered]@{ domain_suffix = $gameDirectDomains; outbound = 'direct' } }
    }

    $ruleSets = @()
    $srs = Join-Path $p.RulesDir 'geoip-ru.srs'
    if (Test-Path -LiteralPath $srs) {
        $ruleSets += [ordered]@{ type = 'local'; tag = 'geoip-ru'; format = 'binary'; path = $srs }
    }

    $route = [ordered]@{
        rules                    = $routes
        final                    = 'direct'
        default_domain_resolver  = $resolver
    }
    if ($ruleSets.Count -gt 0) { $route['rule_set'] = $ruleSets }

    $cfg = [ordered]@{
        log       = [ordered]@{ level = 'warn'; timestamp = $true }
        dns       = $dns
        inbounds  = $inbounds
        outbounds = $outbounds
        route     = $route
    }
    $cfg
}

function Write-FftiConfig {
    param([switch]$ProxyOnly, [string]$Path)
    $p = Get-FftiPaths
    if (-not $Path) { $Path = $p.ConfigFile }
    $cfg = New-FftiConfig -ProxyOnly:$ProxyOnly
    Write-FftiText -Path $Path -Text ($cfg | ConvertTo-Json -Depth 20)
    $Path
}

function Test-FftiConfig {
    param([string]$Path)
    $sb = Get-FftiSingBox
    if (-not $Path) { $Path = (Get-FftiPaths).ConfigFile }
    $out = & $sb check -c $Path 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join [Environment]::NewLine) }
}
