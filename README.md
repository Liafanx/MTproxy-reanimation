# MTproxy-reanimation

**MTproxy-reanimation** — утилита для серверов с **[Telemt](https://github.com/drkctrl/telemt) / [MTProxyMax](https://github.com/SamNet-dev/MTProxyMax) / других ТГ прокси**, которая стабилизирует первичное TCP-подключение клиентов с помощью **inbound SYN limiter через nftables** или **Zapret2** и применяет базовый безопасный тюнинг Telemt.

За основу взяты мануалы сообщества: [Ссылка №1](https://h1de0x.github.io/telemt-tune) · [Ссылка №2](https://assyoucandy.github.io/telemt-server-guide/) · [Ссылка №3](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html) · [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

## 📋 Оглавление

1. [Реклама](#реклама)
2. [Установка и обновление](#установка-и-обновление)
3. [Обновления](#обновления)
4. [Требования](#требования)
5. [Что делает](#что-делает)
6. [Советы](#советы)
7. [Режимы SYN Limiter](#режимы-syn-limiter)
8. [Zapret2 MTProto fix](#zapret2-mtproto-fix)
9. [Параметры тюнинга](#параметры-тюнинга)
10. [Управление параметрами Telemt](#управление-параметрами-telemt)
11. [iOS фиксы](#ios-фиксы-устаревшее)
12. [Основные команды](#основные-команды)
13. [Если используется MTProxyMax](#если-используется-mtproxymax)
14. [Если используется голый Telemt или Docker](#если-используется-голый-telemt-или-docker)
15. [Удаление](#удаление)
16. [Важно](#важно)
17. [Благодарности](#благодарности)
18. [Поддержать автора](#поддержать-автора)

---

<a id="реклама"></a>

## Реклама

Сделал свой Прокси менеджер ставится в докере, вся установка автоматическая, образ есть в GitHub, управление через tui меню со встроенным syn limiter (реаниматором), версия 1.1.6 https://github.com/Liafanx/MTProxyL

<a id="установка-и-обновление"></a>

## Установка и обновление

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/install.sh | sudo bash
```

После установки запускается мастер настройки. При повторной установке — обновляет скрипт.  
Скрипт **автоматически проверяет обновления** при каждом запуске `mtpr`.

Открыть меню:

```bash
mtpr
```

Перед использованием ознакомьтесь с README и обратите внимание на раздел [«Советы»](#советы).

<a id="обновления"></a>

## Обновления

<details> 
<summary><b>1.2.5-1.2.8 от 29.07.2026</b></summary>

- Добавлена поддержка работы Zapret2 для Telemt в контейнере в режиме Bridge.
- В цепочку forward таблицы MTProto для Docker bridge добавлена поддержка фильтрации по IP контейнера в точном режиме (DOCKER_BRIDGE_MODE="precise" → заполнение ip daddr и ip saddr адресом контейнера).
- Проверена и обеспечена полная совместимость службы отслеживания смены IP контейнера (generate_bridge_watch_script / mtpr-bridge-watch.service) с Zapret2 (mtpr-zapret2.service).
- Исправлены некоторые баги, улучшено управление Zapret2.

</details>

<details>
<summary><b>1.2.3-1.2.4 от 27.07.2026</b></summary>

-исправлен Ip адрес контейнера в правилах NFT Smart
-исправлена остановка и повторный запуск zapret2

</details>

<details>
<summary><b>1.2.2 от 27.07.2026</b></summary>

### Zapret2 MTProto fix — крупное обновление

#### Улучшена логика iOS bypass

Ранее iOS-соединения просто пропускались (`VERDICT_PASS`). Теперь они маркируются через `fwmark = 0x40000` и отправляются через `rawsend_dissect_segmented` — это позволяет избежать повторного попадания пакета в очередь через NFT `ct mark`.

#### Обновлена логика ACK window

Добавлено запоминание начального `th_ack` при SYN+ACK. Пустые ACK от сервера теперь зажимают окно только до момента, когда клиент отправил первый payload (`th_ack - ack0 >= 1400`) — после чего соединение отпускается через `fwmark + instance_cutoff`.

#### Обновлена NFT таблица

Добавлена новая цепочка `output` (type route, priority mangle) для корректной работы `ct mark`. Добавлены правила `ct mark accept` в `postrouting` и `prerouting` — повторно обработанные пакеты пропускаются без попадания в очередь. Все правила получили `counter` для мониторинга.

Новая структура таблицы:
```
table ip MTProto {
    chain predefrag   # output priority -401: fwmark accept + notrack
    chain output      # route mangle: ct mark set для marked пакетов
    # Для режима Host / Local:
    chain postrouting # srcnat+1: ct mark accept + queue на sport
    chain prerouting  # mangle: ct mark accept + queue на dport
    # Для режима Docker bridge:
    chain forward     # filter forward priority mangle: ct mark accept + queue на dport/sport
}
```

#### Параметры out-range и in-range изменены на `a` (always)

Ранее использовались значения `-s1`. Теперь оба параметра по умолчанию установлены в `a` — Lua обрабатывает все пакеты и сама решает когда остановиться через `instance_cutoff`.

#### Исправлена переустановка — пересоздаётся служба и скрипт запуска

`zapret2_update_config()` теперь вызывает `zapret2_write_service()` и `zapret2_apply_nft()` при каждом изменении параметров — скрипт запуска `/usr/local/sbin/mtpr-zapret2-start.sh` и systemd unit всегда актуальны.

#### Добавлена проверка TCP wscale и расчёт win ACK

Новый пункт в диагностике `[7]` и при установке — проверяет `net.core.rmem_max` / `net.ipv4.tcp_rmem`, рассчитывает `wscale` ядра и проверяет соответствие текущего `win ACK` требованиям обхода:

- Реальное окно = `win_ACK × 2^wscale` должно быть **< 1400 байт**
- Если текущее значение не подходит — предлагает автоматически скорректировать
- Если `2^wscale ≥ 1400` — выводит предупреждение и инструкцию по уменьшению буфера

#### Добавлена кнопка сброса настроек к дефолту

В меню zapret2 добавлен пункт `[r] Сбросить настройки к значениям по умолчанию` — с подтверждением сбрасывает все параметры и перезапускает службу.

### Изменения первой установки

- **Zapret2 fix предлагается первым** — до выбора SYN limiter
- **По умолчанию Y** — при нажатии Enter zapret2 устанавливается
- **Если zapret2 установлен** — выбор SYN limiter и действия для non-iOS пропускается
- **Оптимизация By-MEKO** — теперь по умолчанию Y
- **iOS фиксы (v1, v2)** убраны из мастера первой установки — доступны в меню `[o] Устаревшие настройки`

### Изменения главного меню

- **Zapret2 fix** поднят на уровень Smart By-MEKO — в самый верх меню
- **Счётчик правил `[5]`** теперь умный:
  - только zapret2 → показывает правила zapret2 с `counter`/`queue`/`notrack`/`ct mark`
  - только SYN limiter → показывает как раньше
  - оба активны → показывает обе таблицы одновременно
- **iOS фиксы v1/v2** убраны из главного меню → перемещены в `[o] Устаревшие настройки`
- **Шапка меню** при активном zapret2 и неактивном лимитере не показывает NFT режим, службу лимитера, Rate/Burst/Timeout — только актуальные данные
- **iOS фикс v1/v2** в шапке показывается только если применён
- **Zapret2 fix** в шапке отображается перед NFT правилами

### Настройки Smart режима

- В меню настроек `[3]` Rate/Burst/Timeout скрыты при не-Classic режиме
- При попытке изменить через цифры — выводится подсказка

### Прочее

- Пресеты Classic в мастере и меню пресетов сокращены до одного (жёсткий + свой вариант)
- Средний и мягкий пресеты удалены из UI (код оставлен для обратной совместимости)

</details>

<details>
<summary><b>1.2.0-1.2.1 от 25.07.2026</b></summary>

### Zapret2 MTProto fix

Добавлен новый режим обхода — **Zapret2 MTProto fix**.

Это принципиально другой подход по сравнению с SYN limiter:

- **SYN limiter** ([Smart By-MEKO](#-smart-by-meko-рекомендуется) / Classic) — ограничивает количество входящих SYN-пакетов от клиента. Работает как защита от спама подключений и помогает клиенту быстрее "выбрать" рабочий путь.
- **Zapret2 fix** — работает на уровне TCP-пакетов и активно запутывает анализ первого handshake.

#### Как работает Zapret2 fix

1. **SYN+ACK с маленьким окном** — сервер отвечает на SYN клиента с `window=1400`. Клиент вынужден дробить первый пакет.
2. **ACK давление** — пустые ACK от сервера до прихода первого payload идут с `window=10`. Клиент не торопится отправить всё сразу.
3. **Split + disorder + badsum** — первый data-пакет клиента (ClientHello) режется на 3 части:
   - первая часть → отправляется нормально
   - третья часть → отправляется нормально со смещением
   - вторая (средняя) часть → отправляется с **испорченной контрольной суммой**
4. Видно неполный/перепутанный ClientHello — его нельзя проанализировать.
5. Сервер отбрасывает битую среднюю часть → клиент ретрансмитирует → соединение устанавливается.
6. Дальнейший трафик идёт без вмешательства.

#### Что заменяет

Zapret2 fix **заменяет** SYN limiter (Smart By-MEKO / Classic) — при его включении SYN limiter автоматически отключается.

#### Совместимость

Zapret2 fix использует [zapret2](https://github.com/bol-van/zapret2) — пакетный манипулятор с Lua-скриптами. Бинарники скачиваются автоматически из официального репозитория при установке.

- Требует Linux с `nftables`
- Работает с любым Telemt / MTProxyL / MTProxyMax / Docker (включая режим bridge с nft цепочкой forward), и в теории с другими MTProto прокси

</details>

<details>
<summary><b>1.1.4 от 06.07.2026</b></summary>

### Мелкие фиксы
- По умолчанию теперь iOS клиенты не режутся лимитером
- Добавлен вывод трафика накопленного через меню `[L] Ссылки прокси + уникальные подключения + трафик`

</details>

<details>
<summary><b>1.1.2-1.1.3 от 03.07.2026</b></summary>

### Ссылки прокси через API Telemt

Добавлен новый пункт меню `[l] Ссылки прокси` — выводит актуальные `tg://proxy?...` ссылки для каждого пользователя напрямую из Telemt API (`/v1/users`).

- Отображает всех пользователей с их статусом, количеством подключений и уникальных IP
- Автоматически фильтрует IPv6-ссылки (`server=::`)
- Поддерживает `public_host` и `public_port` из секции `[general.links]` конфига Telemt
- Работает через `jq` (добавлен в автоустановку зависимостей)
- API порт определяется автоматически из секции `[server.api]` конфига (по умолчанию `9091`)

### Управление параметрами Telemt (MSS)

Добавлен новый пункт меню `[p] Параметры Telemt` — управление `client_mss`, `client_mss_bulk` без ручного редактирования конфига.

### Проверка ограничений сервера

Добавлен пункт `[x] Проверка ограничений сервера` — через [censorcheck.tlab.pw](https://censorcheck.tlab.pw).

### Статус Telemt и параметры MSS в шапке

Добавлены: статус сервиса Telemt, значения `client_mss` / `client_mss_bulk`.

</details>

<details>
<summary><b>1.1.1 от 01.07.2026</b></summary>

### Smart By-MEKO — добавлена обратная совместимость

Добавлена возможность выбора метода определения iOS в Smart режиме:

- **TCP fingerprint** (по умолчанию) — точное определение по SYN payload
- **TTL + Length** (устаревший) — `ip ttl < 65 AND meta length 64`

Переключается через `Меню → [c] → [9] Метод идентификации iOS`.

</details>

<details>
<summary><b>1.1.0 от 30.06.2026</b></summary>

### Smart By-MEKO — обновление логики

- iOS теперь определяется по **TCP SYN fingerprint** вместо `TTL + Length`
- Добавлена возможность полностью отключать лимиты отдельно для iOS и Other
- Настраивается через `Меню → [c] Настройки Smart режима`

</details>

<details>
<summary><b>1.0.11 от 28.06.2026</b></summary>

- Улучшен режим **NFT Smart By-MEKO** — исправлена проблема с долгой отправкой медиа на Android/Desktop
- Добавлен выбор действия для non-iOS: `icmp-host-unreachable` (по умолчанию), `reject`, `drop`

</details>

<details>
<summary><b>1.0.10 от 26.06.2026</b></summary>

- **Оптимизация системы By-MEKO** — новый пункт меню `[m]`
  - TCP keepalive `time=45 / intvl=15 / probes=3`, BBR, расширенные очереди
  - Полный откат к исходным значениям ядра

</details>

<details>
<summary><b>1.0.9 от 25.06.2026</b></summary>

- Добавлен **NFT Smart By-MEKO** — рекомендуемый режим SYN limiter
  - Один порт для всех клиентов, REJECT вместо DROP, подключение 3-8 сек

</details>

<details>
<summary><b>1.0.4–1.0.8 от 11–16.06.2026</b></summary>

- iOS фиксы v1 (TCP keepalive) и v2 (MSS + redirect)
- Восстановление конфигурации из бэкапа при удалении
- Docker bridge: простой и точный режим
- Автоматическая проверка обновлений при запуске

</details>

<a id="требования"></a>

## Требования

- Linux с [`systemd`](https://systemd.io/)
- [`nftables`](https://wiki.nftables.org/) (устанавливается автоматически)
- `curl`
- `jq` (устанавливается автоматически)
- Права `root`

<a id="что-делает"></a>

## Что делает

- Находит **[Telemt](https://github.com/drkctrl/telemt)** автоматически: MTProxyMax, Docker, systemd, локальный процесс
- **Telemt Panel** игнорируется — её конфиги не затрагиваются
- Определяет нужный netfilter hook:
  - `input` — если Telemt работает на хосте / через host network
  - `forward` — если Telemt работает в Docker bridge
- Для Docker bridge предлагает два режима:
  - **Простой режим** — правило только по порту
  - **Точный Docker-режим** — внутренний IP контейнера + watcher
- Применяет **per-client inbound SYN limiter** через nftables — [Classic](#classic-режим) и [Smart By-MEKO](#-smart-by-meko-рекомендуется)
- В **[Smart By-MEKO](#-smart-by-meko-рекомендуется)** режиме:
  - автоматически распознаёт **iOS** по **TCP SYN fingerprint**
  - отдельно обрабатывает **iOS** и **Other / Android / Desktop**
  - позволяет выбрать действие для non-iOS клиентов: `icmp-host-unreachable` / `reject` / `drop`
  - позволяет **полностью отключить лимит** отдельно для iOS / Other
- **[Zapret2 MTProto fix](#zapret2-mtproto-fix)** — серверный обход через packet mangling (disorder + badsum + window control + ct mark)
- Выводит **ссылки прокси** по пользователям через Telemt API с учётом `public_host` / `public_port`
- Управляет параметрами конфига Telemt: `client_mss`, `client_mss_bulk`
- Безопасно применяет тюнинг Telemt (с бэкапом конфига перед изменениями)
- При удалении может восстановить конфигурацию из сохранённого бэкапа
- Ставит systemd-службу с автозапуском

<a id="советы"></a>

## Советы

- Поставьте реаниматор, на все нажмите Enter — при первой установке по умолчанию предлагается **[Zapret2 MTProto fix](#zapret2-mtproto-fix)**, затем **[Smart By-MEKO](#-smart-by-meko-рекомендуется)**.
- В 95% случаев всё заводится на Стандартный конфиг + Реаниматор.
- Используя любой вариант решения syn ограничений, необходимо убедиться в том, что домен, используемый для Fake TLS имеет поддержку постквантового гибридного алгоритма обмена ключами. Проверить это можно с помощью ТГ бота [@Sni_checker_bot](https://t.me/Sni_checker_bot) — отправьте ему домен:
  - 🟢 сервер принимает X25519MLKEM768 — отлично
  - 🔴 PQ не поддерживается + Peer Temp Key = X25519 — iOS устройства не смогут подключиться
- **[Zapret2 fix](#zapret2-mtproto-fix)** предлагается первым при установке — рекомендуется попробовать его. При его использовании `client_mss` в конфиге Telemt лучше отключить через `[p] Параметры Telemt`.
- При **[Smart режиме](#-smart-by-meko-рекомендуется)** `client_mss` в конфиге не нужен — лучше отключить через `[p] Параметры Telemt`.
- В **Smart By-MEKO** iOS определяется по **TCP SYN fingerprint** — точнее чем старый метод TTL + Length.
- Управление лимитами Smart режима: `Меню → [c] Настройки Smart режима`
- При **[Classic режиме](#classic-режим)** `client_mss = tspu` тоже не работает в большинстве случаев — лучше закомментировать через `[p] Параметры Telemt`.
- Если у вас `telemt` в Docker bridge:
  - сначала пробуйте **Точный Docker-режим**
  - если не помогает — **Простой режим**
- Если у вас Double Hop, ставьте реаниматор на входящей ноде. Скрипт скажет, что не находит telemt — это нормально. Просто нажимайте Enter, но укажите правильный порт (обычно 443).
- В последних версиях telemt 3.4.18+ были добавлены функции, которые использует реаниматор — выбирайте что-то одно, либо новые параметры в telemt, либо реаниматор.
- Если удаляете реаниматор и выбираете восстановление из бэкапа — все изменения, внесённые в конфиг Telemt после установки реаниматора, будут потеряны.
- При **Smart режиме** для non-iOS по умолчанию рекомендуется **`icmp-host-unreachable`** — Telegram быстрее переключается на рабочее соединение, нет задержки при отправке медиа на Android/Desktop.
- Ссылки прокси выводятся через `[l]` — API должен быть включён в конфиге Telemt (`[server.api] enabled = true`).
- **iOS фиксы v1/v2** перемещены в `[o] Устаревшие настройки` — при Smart или Zapret2 они не нужны.
- **Zapret2 win ACK** рассчитывается автоматически при установке с учётом `wscale` вашего ядра. Если обход не работает — проверьте через `[z] → [7] Диагностика`.

<a id="режимы-syn-limiter"></a>

## Режимы SYN Limiter

MTproxy-reanimation поддерживает два режима — выбрать можно при установке или в любой момент через меню.

### ★ Smart By-MEKO *(рекомендуется)*

> Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO) — спасибо автору за идею.

Интеллектуальный режим с автоматическим разделением клиентов по **TCP SYN fingerprint**.

### Как работает Smart

Smart делит входящие SYN-подключения на две ветки:

- **iOS** — распознаются по **TCP SYN fingerprint**
- **Other / Android / Desktop** — все остальные SYN

Используется следующий fingerprint iOS:

```nft
@th,108,20 0x2ffff
@th,160,16 0x204
@th,192,16 0x103
@th,224,24 0x10108
@th,320,32 0x4020000
```

### Логика по умолчанию

```nft
# iOS по TCP fingerprint → мягкий лимит → accept
tcp dport PORT tcp flags & (syn | ack) == syn \
@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 \
@th,224,24 0x10108 @th,320,32 0x4020000 \
meter mtpr_ios { ip saddr timeout 60s limit rate 15/second burst 30 packets } accept

# iOS сверх лимита → tcp reset
tcp dport PORT tcp flags & (syn | ack) == syn \
@th,108,20 0x2ffff ... reject with tcp reset

# Остальные → строгий лимит → accept
tcp dport PORT tcp flags & (syn | ack) == syn \
meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } accept

# Остальные сверх лимита → ICMP host-unreachable (по умолчанию)
tcp dport PORT tcp flags & (syn | ack) == syn \
reject with icmp type host-unreachable
```

### Ключевые отличия от Classic

| | Classic | Smart By-MEKO |
|---|---|---|
| **iOS / остальные** | один общий лимит | раздельные ветки по **TCP fingerprint** |
| **При превышении** | DROP → клиент ждёт 3-5 сек | REJECT / ICMP → быстрый fallback |
| **Время подключения** | 10-20 сек | **3-8 сек** |
| **Порты** | один для всех | **один порт для всех** |
| **Гибкость** | только rate/burst | можно **полностью отключать лимит** отдельно для iOS / Other |

**Что не нужно при Smart режиме:**
- iOS Fix v2 (MSS + отдельный порт 4443)
- `client_mss` в конфиге telemt

### Classic режим

Традиционный per-client SYN limiter:

```nft
tcp dport <PORT>
tcp flags & (syn | ack) == syn
meter { ip saddr timeout 60s limit rate over 1/second burst 1 packets }
counter drop
```

### Пресеты

| Пресет | Режим | Rate | Burst | Action | Описание |
|--------|-------|------|-------|--------|----------|
| **★ Smart** | Smart | iOS: 15/sec / Other: 54/min | 30 / 1 | **icmp-host-unreachable** | Рекомендуется |
| **Жёсткий** | Classic | 1/second | 1 | DROP | Строгое ограничение |

<a id="zapret2-mtproto-fix"></a>

## Zapret2 MTProto fix

Альтернативный режим обхода, использующий активное манипулирование TCP-пакетами на уровне ядра через [zapret2](https://github.com/bol-van/zapret2).

### Отличие от SYN limiter

| | SYN limiter | Zapret2 fix |
|---|---|---|
| **Принцип** | ограничение входящих SYN | манипуляция TCP-пакетами |
| **Уровень** | SYN-пакеты | весь начальный handshake |
| **Клиент** | ничего не нужно | ничего не нужно |
| **Совместимость** | все серверы | требует [zapret2](https://github.com/bol-van/zapret2) (nfqws2) |
| **При включении** | — | SYN limiter отключается |

### Как включить

```bash
mtpr
# → [Z] Zapret2 MTProto fix
# → [1] Установить
```

### Как работает

1. Сервер отвечает на SYN клиента с уменьшенным TCP window (1400 байт) → клиент вынужден дробить ClientHello
2. Сервер запоминает начальный ACK. Пустые ACK идут с `window=10` пока клиент не отправил payload
3. Когда клиент отправил первый payload — соединение отпускается через `fwmark + ct mark`
4. Первый data-пакет (ClientHello) режется на 3 части:
   - 1-я часть → нормально
   - 3-я часть → нормально со смещением
   - 2-я часть → с **битой контрольной суммой** (badsum)
5. Нельзя собрать ClientHello → пропускает соединение
6. Клиент ретрансмитирует среднюю часть → соединение устанавливается штатно
7. Дальше трафик без вмешательства

#### iOS fingerprint bypass

iOS-клиенты автоматически определяются по TCP SYN fingerprint и маркируются через `fwmark` — они проходят без манипуляций с окном, что предотвращает деградацию их подключений.

### NFT таблица

```
table ip MTProto {
    chain predefrag   # output -401: пропуск помеченных + notrack
    chain output      # route mangle: ct mark set для marked пакетов
    # Режим host/local:
    chain postrouting # srcnat+1: ct mark accept + queue на порт
    chain prerouting  # mangle: ct mark accept + queue на порт
    # Режим Docker bridge:
    chain forward     # filter forward priority mangle: ct mark accept + queue на dport/sport
}
```

### Проверка wscale и win ACK

Эффективность обхода зависит от **TCP window scale** (`wscale`), который ядро сервера выставляет исходя из размера буфера. Скрипт автоматически проверяет это при установке и в диагностике:

```
Реальное окно = win_ACK × 2^wscale  →  должно быть < 1400 байт
```

| wscale | 2^wscale | Рекомендуемый win ACK | Реальное окно |
|--------|----------|-----------------------|---------------|
| 7 | 128 | 10 | 1280 байт ✓ |
| 9 | 512 | 2 | 1024 байт ✓ |
| 11 | 2048 | — | **невозможно** ✗ |

При `wscale ≥ 11` (буфер 64 МБ+) скрипт выведет инструкцию по уменьшению `net.core.rmem_max`.

### Автозапуск после перезагрузки

NFT-правила и nfqws2 применяются автоматически через `mtpr-zapret2.service`. Перезагрузка не требует ручного вмешательства.

### Настраиваемые параметры

Через меню `[Z] → [4] Настройки`:

| Параметр | Умолч. | Описание |
|----------|:------:|---------|
| out-range | `a` | Диапазон обработки исходящих пакетов (always) |
| in-range | `a` | Диапазон обработки входящих пакетов (always) |
| split len | `400` | Размер частей при разрезании ClientHello |
| win SYN+ACK | `1400` | TCP window в SYN+ACK |
| win ACK | `10` | TCP window в пустых ACK (рассчитывается по wscale) |

#### Управление out-range / in-range

| Режим | Что считает | Пример |
|-------|-------------|--------|
| `a` | всегда (Lua решает сама) | `a` |
| `n` | номер пакета | `-n5` = первые 5 пакетов |
| `s` | TCP rseq начала | `-s1` = пока rseq < 1 |
| `d` | пакеты с payload | `-d1` = до первого data-пакета |
| `b` | байты payload | `-b1000` = до 1000 байт |
| `x` | никогда | `x` |

### Управление из меню

```bash
mtpr → [Z]   # Открыть меню zapret2
```

| Пункт | Действие |
|-------|---------|
| `[1]` | Установить / переустановить |
| `[2]` | Перезапустить |
| `[3]` | Остановить |
| `[4]` | Настройки параметров |
| `[5]` | Показать конфиг + Lua + NFT |
| `[6]` | Логи службы |
| `[7]` | Диагностика (wscale + queue + NFT) |
| `[r]` | Сбросить настройки к дефолту |
| `[8]` | Удалить |

### Команды управления

```bash
# Статус службы
systemctl status mtpr-zapret2 --no-pager

# Логи
journalctl -u mtpr-zapret2 -n 50 --no-pager

# NFT таблица с счётчиками
nft list table ip MTProto
```

---

<a id="параметры-тюнинга"></a>

## Параметры тюнинга

| Параметр | По умолчанию | Описание |
|----------|:---:|-----------|
| `tg_connect` | 30 | Таймаут подключения к Telegram DC |
| `client_handshake` | 90 | Ожидание начального handshake |
| `client_keepalive` | 120 | Ожидание активности клиента |

Все параметры можно изменить в настройках скрипта (пункт `[3]`).

<a id="управление-параметрами-telemt"></a>

## Управление параметрами Telemt

Через пункт меню `[p] Параметры Telemt` можно управлять:

| Параметр | Описание |
|----------|-----------|
| `client_mss` | MSS для клиентских соединений. **Не рекомендуется при Smart и Zapret2** |
| `client_mss_bulk` | MSS для bulk-трафика |

Доступные действия: установить значение, отключить (закомментировать), включить MSS-пресет (`client_mss=tspu` + `client_mss_bulk=1400`), отключить все сразу.

<a id="ios-фиксы-устаревшее"></a>

## iOS фиксы *(устаревшее)*

Доступны через `[o] Устаревшие настройки` в главном меню. При использовании **Smart By-MEKO** или **Zapret2 fix** они не нужны.

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`. По умолчанию: `time=60, intvl=15, probes=3`.

### Вариант 2 — MSS + redirect *(только Classic режим)*

Создаёт отдельный порт для iOS (по умолчанию **4443**) с MSS=92 и прозрачным редиректом на основной порт Telemt.

```
было:  tg://proxy?server=IP&port=443&secret=...
стало: tg://proxy?server=IP&port=4443&secret=...
```

<a id="основные-команды"></a>

## Основные команды

```bash
mtpr    # Открыть меню управления
```

### Проверить активную службу

```bash
# SYN limiter (обычный и Smart By-MEKO)
systemctl status mtpr-syn-limit.service --no-pager

# Точный Docker-режим
systemctl status mtpr-bridge-watch.service --no-pager

# Zapret2 fix
systemctl status mtpr-zapret2 --no-pager
```

### Посмотреть текущие nft-правила

```bash
# SYN limiter
nft list table inet telemt_limit

# Zapret2 fix
nft list table ip MTProto
```

### Посмотреть все правила Reanimation

```bash
nft list ruleset | grep -A20 -B5 mtpr
```

### Получить ссылки прокси вручную (без меню)

```bash
curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[] | .username, (.links.tls[] | select(contains("server=::") | not))'
```

<a id="если-используется-mtproxymax"></a>

## Если используется MTProxyMax

Тюнинг применяется через штатные команды, без прямого редактирования `config.toml`.

Для отката:

```bash
mtproxymax tune clear tg_connect
mtproxymax tune clear client_handshake
mtproxymax tune clear client_keepalive
mtproxymax restart
```

<a id="если-используется-голый-telemt-или-docker"></a>

## Если используется голый Telemt или Docker

Перед изменением `telemt.toml` или `config.toml` создаётся бэкап (`*.mtpr-backup-*`).

Для отката:

```bash
ls /etc/telemt/telemt.toml.mtpr-backup-*
cp /etc/telemt/telemt.toml.mtpr-backup-<timestamp> /etc/telemt/telemt.toml
systemctl restart telemt
```

<a id="удаление"></a>

## Удаление

Из меню: клавиша `u` / `U`

При удалении скрипт предложит:
- восстановить конфигурацию Telemt из бэкапа
- или оставить бэкап на диске для ручного восстановления позже

<a id="важно"></a>

## Важно

- Скрипт **не трогает** конфиги Telemt Panel
- Скрипт **не является заменой** Telemt или MTProxyMax
- NFT-правила работают на уровне ядра
- В Docker bridge режиме сначала пробуйте **Точный Docker-режим**, если не помогает — **Простой режим**
- **Smart By-MEKO** в bridge/precise режиме работает без `ip daddr` контейнера — идентификация iOS идёт по **TCP fingerprint**
- **Zapret2 fix** и **SYN limiter** не используются одновременно — при включении zapret2 лимитер автоматически отключается
- При использовании **Zapret2 fix** параметр `client_mss` лучше отключить через `[p] Параметры Telemt`
- После перезагрузки сервера **Zapret2 fix** восстанавливает NFT-правила автоматически через systemd
- **win ACK** в Zapret2 рассчитывается под конкретный сервер — при смене буферов ядра проверяйте через `[z] → [7] Диагностика`
- Для вывода ссылок прокси через `[l]` необходимо чтобы в конфиге Telemt был включён API (`[server.api] enabled = true, listen = "127.0.0.1:9091"`)
- Если удаляете реаниматор и выбираете восстановление из бэкапа — все изменения, внесённые в конфиг Telemt после установки, будут потеряны

---

<a id="благодарности"></a>

## Благодарности

- **[MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)** — идея Smart режима: разделение iOS/Android по TCP fingerprint и использование быстрого REJECT вместо классического DROP

---

<a id="поддержать-автора"></a>

## Поддержать автора

Если хотите поддержать проект, закинуть на пачку кириешек:
- [Cloudtips](https://pay.cloudtips.ru/p/ad2f7e4d)
- GRAM (TON) ```UQCcJR7546fnGX7jnJeFQdTUVMezVIvxutn074UezGOy_w8n```
- USDT (TRC20) ```TJKiqjDX7nLihV3ACJdJ9cgPwM169L2xmB```
- USDT (BER20) ```0xBf96ADb7c81eab25E56d7c40Bd414582E5B714A1```

---

MTproxy-reanimation by LiafanX · [GitHub](https://github.com/Liafanx/MTproxy-reanimation)

## Star History

<a href="https://www.star-history.com/?repos=Liafanx%2FMTproxy-reanimation&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Liafanx/MTproxy-reanimation&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Liafanx/MTproxy-reanimation&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Liafanx/MTproxy-reanimation&type=date&legend=top-left" />
 </picture>
</a>
