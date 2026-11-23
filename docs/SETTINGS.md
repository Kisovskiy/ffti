# Настройки FFTI

Базовые значения — `settings\default.json`. Свои правки пиши в `settings\user.json` (или командой
`ffti.bat set <ключ> <значение>`) — при обновлении проекта они сохраняются. Приоритет:
`default.json` → `user.json` → патч режима из `modes.json`.

## Общие

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `mode` | `web` | активный режим: `web`, `game`, `max`, `roblox` или свой |

## tunnel

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `enabled` | `false` | поднимать ли туннель |
| `network` | `tun` | `tun` — перехватывается весь трафик; `proxy` — только локальные порты 1080/1081, программу настраиваешь сам |
| `mtu` | `1400` | размер пакета туннеля; 1420 — в режиме game |
| `tunAddress` | `172.19.0.1/30` | внутренний адрес туннеля; меняй, если конфликтует с твоей сетью |
| `stack` | `system` | реализация стека: `system` — быстрее на слабых CPU |
| `autoRoute` | `true` | сам прописывать маршруты |
| `strictRoute` | `true` | не выпускать трафик мимо туннеля |
| `localHttpPort` | `1081` | локальный HTTP-прокси |
| `localSocksPort` | `1080` | локальный SOCKS5-прокси |
| `lanBypass` | `true` | локальная сеть и принтеры — напрямую |
| `ruBypass` | `true` | российские подсети не попадают в туннель вообще |

## dns

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `mode` | `system` | `system` — системный резолвер (самый быстрый старт), `split` — свои DNS для РФ и остальных |
| `ru` | `77.88.8.8` | DNS для российских адресов в режиме `split` |
| `global` | `9.9.9.9` | DNS для остального в режиме `split` |
| `strategy` | `prefer_ipv4` | как выбирать адрес: `prefer_ipv4`, `prefer_ipv6`, `ipv4_only` |

## performance

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `tcpFastOpen` | `true` | быстрее установка соединений |
| `sniff` | `true` | определять домен по соединению — иначе правила по доменам не работают |
| `urltestUrl` | `https://discord.com` | чем проверять прокси пула |
| `urltestInterval` | `2m` | как часто перевыбирать лучший прокси |
| `urltestTolerance` | `200` | насколько новый прокси должен быть лучше, чтобы переключиться (мс) |
| `proxyDns` | `false` | резолвить через туннель; медленнее, включай только если DNS режут |

## dpi

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `enabled` | `false` (в режимах `web`/`game`/`max` — `true`) | включён ли DPI-слой |
| `profile` | `off` | `off`, `google`, `general`, `games`, `max`, `full` |
| `zapretDir` | автопоиск | папка с `bin\winws.exe` и `lists\` |
| `repeats` | `11` | сколько раз дублировать первый пакет; меньше — мягче, больше — надёжнее |
| `fakeTls` / `fakeQuic` | свои из набора | файлы-подмены для TLS и QUIC |
| `hostlist` / `ipset` | — | свои списки доменов и IP для DPI |

Профили DPI:

| Профиль | Что покрывает |
|---|---|
| `off` | выключен |
| `google` | YouTube и Google (TCP 443 + QUIC) — минимальная нагрузка |
| `general` | + общий список доменов и IP-набор |
| `games` | порты игр, голосовой чат Discord, STUN |
| `max` | `general` без игровых правил |
| `full` | `general` + `games` — максимальный охват |

## games

| Ключ | По умолчанию | Что задаёт |
|---|---|---|
| `robloxAssist` | `false` | пускать веб-логин Roblox через туннель (игровые серверы — нет) |
| `robloxDirect` | `true` | Roblox-серверы и CDN всегда напрямую |
| `keepGameTrafficDirect` | `true` | игровые подсети не пускать в туннель ни при каких правилах |
| `discordVoice` | `true` | не ломать голосовой чат (DPI-профили `games`/`full`) |

## lists

| Ключ | Что задаёт |
|---|---|
| `proxies` | файл пула прокси |
| `proxyDomains`, `proxyIps` | что уходит в туннель |
| `gamesDomains`, `gamesIps` | что всегда напрямую |
| `robloxDomains` | Roblox-веб для режимов roblox/game |
| `autoRefreshHours` | `0` — обновлять пул вручную; `6`, `12`, `24` — раз в N часов при включении |

## Примеры

```
ffti.bat set dpi.enabled false
ffti.bat set tunnel.mtu 1380
ffti.bat set performance.urltestInterval 1m
ffti.bat set dns.mode split
ffti.bat set games.robloxAssist true
```
