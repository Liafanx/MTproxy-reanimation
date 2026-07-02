# MTproxy-reanimation

**MTproxy-reanimation** — утилита для серверов с **Telemt / MTProxyMax / других ТГ прокси**, которая стабилизирует первичное TCP-подключение клиентов с помощью **inbound SYN limiter через nftables** и применяет базовый безопасный тюнинг Telemt.

За основу взяты мануалы сообщества: [Ссылка №1](https://h1de0x.github.io/telemt-tune) · [Ссылка №2](https://assyoucandy.github.io/telemt-server-guide/) · [Ссылка №3](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html) · [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

## Реклама

Сделал свой Прокси менеджер ставится в докере, вся установка автоматическая, образ есть в GitHub, управление через tui меню со встроенным syn limiter, версия 1.0.9 https://github.com/Liafanx/MTProxyL

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

Перед использованием ознакомьтесь с README и обратите внимание на раздел «Советы».

## Обновления

<details>
<summary><b>1.1.1 от 01.07.2026</b></summary>

### Smart By-MEKO — добавлена обратная совместимость

Добавлена возможность выбора метода определения iOS в Smart режиме.

Теперь доступны два варианта:

#### ✅ 1. TCP fingerprint (по умолчанию, рекомендуется)

Определение iOS по TCP SYN payload:

```
@th,108,20 0x2ffff
@th,160,16 0x204
@th,192,16 0x103
@th,224,24 0x10108
@th,320,32 0x4020000
```

- Точное определение iOS
- Независимо от TTL
- Соответствует новому фикс-скрипту MEKO v1.03
- Рекомендуемый режим

#### 🔄 2. TTL + Length (старый режим v1.0.9)

```
ip ttl < 65 AND meta length 64
```

- Добавлен для обратной совместимости
- Можно использовать, если fingerprint по какой-то причине не срабатывает
- Менее точный метод

Переключается через:

```
Меню → [c] Настройки Smart режима → [9] Метод идентификации iOS
```

---

### Улучшено отображение статуса

- В шапке теперь отображается:
  - текущий метод идентификации iOS
  - fingerprint или TTL+Length
- Обновлено описание Smart режима в меню

---

### Поведение Smart режима

По умолчанию:

- iOS → 15/sec burst 30
- Other → 54/min burst 1
- Other превышение → icmp-host-unreachable

Лимиты по-прежнему можно:
- полностью отключить для iOS
- полностью отключить для Other

---

### Зачем это добавлено

Если страрый метод работал, а новый нет.
В таких случаях можно временно вернуться к старому методу TTL+Length,
не откатываясь на старые версии скрипта.

</details>

<details>
<summary><b>1.1.0 от 30.06.2026</b></summary>

### Smart By-MEKO — обновление логики

- Smart режим обновлён под новый фикс **MEKO v1.03**
- Идентификация **iOS** больше не строится на `TTL + Length`
- Теперь iOS определяется по **TCP SYN fingerprint** через payload match:
  - `@th,108,20 0x2ffff`
  - `@th,160,16 0x204`
  - `@th,192,16 0x103`
  - `@th,224,24 0x10108`
  - `@th,320,32 0x4020000`
- Это делает распознавание iOS заметно точнее и ближе к оригинальной логике проекта [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)

### Новое — можно полностью отключать лимиты в Smart режиме

Добавлена возможность **не просто менять rate/burst, а полностью отключать лимиты**:

- **отдельно для iOS**
- **отдельно для Other (Android/Desktop)**

Если лимит отключён:

- iOS fingerprint → `ACCEPT` без meter
- Other → `ACCEPT` без meter

Настраивается через:

- `Меню` → `[c] Настройки Smart режима`

### Поведение Smart режима теперь гибкое

По умолчанию Smart остаётся таким же:

- **iOS** → `15/second burst 30`
- **Other** → `54/minute burst 1`
- **Other сверх лимита** → `icmp-host-unreachable` по умолчанию

Но теперь при необходимости можно сделать:

- iOS без лимита
- Other без лимита
- оба направления без лимита

> Внимание: отключение лимита для **Other** фактически отключает защиту Smart режима для Android/Desktop и прочих клиентов.

### Обновлены тексты и отображение статуса

- В шапке и меню теперь корректно отображается:
  - включён лимит или отключён
  - `unlimited` для iOS / Other, если лимит выключен
- Обновлены описания Smart режима:
  - вместо старого `TTL + Length`
  - теперь везде используется формулировка **TCP fingerprint**

</details>

<details>
<summary><b>1.0.11 от 28.06.2026</b></summary>

- Улучшен режим **NFT Smart By-MEKO** — исправлена проблема с долгой отправкой медиа на Android/Desktop
- Добавлена возможность выбора действия (**Action**) для non-iOS устройств:
  - **icmp-host-unreachable** — новый режим по умолчанию. Сервер притворяется недоступным узлом сети. Это заставляет Telegram мгновенно переключаться на основное рабочее соединение, полностью убирая задержку ("затуп") при начале отправки видео и фото.
  - **reject (tcp reset)** — классический сброс соединения (оригинал By-MEKO). Сохранён для максимальной совместимости.
  - **drop** — тихое уничтожение пакета.
- Теперь при первой установке Smart-режима скрипт предложит выбрать предпочтительное действие (рекомендуется **ICMP**)
- Изменить тип действия для активного Smart-режима можно в любое время через:
  - `Меню` → `[c] Настройки Smart режима` → `[5] Переключить Other Action`
- Доп. правила (**Extra Rules**) в Smart-режиме теперь автоматически наследуют выбранный тип действия (ICMP/REJECT/DROP)
- Обновлена статусная строка: теперь в шапке отображается текущий тип действия для прочих устройств

</details>

<details>
<summary><b>1.0.10 от 26.06.2026</b></summary>

### Новое

- **Оптимизация системы By-MEKO** — новый пункт меню `[m]`
  - Применяет набор sysctl-параметров из проекта [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)
  - TCP keepalive: `time=45 / intvl=15 / probes=3` — ускоряет обнаружение мёртвых сокетов (~90 сек вместо ~2 часов)
  - Расширенные сетевые очереди: `somaxconn`, `tcp_max_syn_backlog`, `netdev_max_backlog` = 65535
  - `tcp_fastopen = 3`, `fs.file-max = 2097152`
  - Алгоритм управления перегрузкой: `BBR` + планировщик очереди `fq`
  - **Полный откат к значениям до применения** — все оригинальные значения ядра сохраняются перед применением и восстанавливаются при откате
  - Автоматический откат при удалении реаниматора (`u`)
  - Предлагается при первой установке
 
</details>

<details>
<summary><b>1.0.9 от 25.06.2026</b></summary>

- Добавлен **NFT Smart By-MEKO** — новый рекомендуемый режим SYN limiter
  - iOS и Android/Desktop разделяются автоматически по TTL+Length — один порт для всех клиентов
  - REJECT с tcp-reset вместо DROP — подключение за **3-8 сек** вместо 10-20
  - iOS Fix v2 и `client_mss` в конфиге не нужны при Smart режиме
  - Все параметры Smart настраиваемы через пункт `[c]` главного меню
  - Источник идеи: [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)
- По умолчанию при первой установке предлагается Smart режим
- Classic режим (hard/medium/soft) сохранён для совместимости
- Доп. правила в Smart режиме тоже используют REJECT вместо DROP
- Статусная строка в шапке показывает текущий режим и параметры

</details>

<details>
<summary><b>1.0.8 от 16.06.2026</b></summary>

- Добавлено восстановление конфигурации из бэкапа при удалении реаниматора
- При удалении можно выбрать:
  - восстановить конфиг из бэкапа
  - или оставить бэкап и восстановить его позже вручную
- Исправлен **Fix для iOS вариант 1**:
  - теперь сохраняются исходные значения `tcp_keepalive_*` перед применением
  - при откате восстанавливаются именно исходные значения, а не жёстко `7200 / 75 / 9`
- Улучшены сообщения при откате и удалении
- Мелкие правки логики и текста в меню

</details>

<details>
<summary><b>1.0.7 от 15.06.2026</b></summary>

- Для Docker bridge добавлен выбор режима:
  - **Простой режим** — правило только по порту
  - **Точный Docker-режим** — внутренний IP контейнера + watcher
- Обновлён README
- Теперь при применении тюнинга недостающие разделы в конфиге могут создаваться через скрипт автоматически

</details>

<details>
<summary><b>1.0.6 от 15.06.2026</b></summary>

- Автоматическая проверка обновлений при запуске
- При установке Fix для iOS №1 по умолчанию N
- Значения в Fix для iOS №1 теперь можно редактировать
- После изменения сетевых параметров скрипт предлагает сразу применить новые NFT-правила (**по умолчанию Y**)
- При первом запуске перед применением тюнинга подробнее показывается, какие параметры будут выставлены
- Если в конфиге Telemt нет секций `[general]` или `[timeouts]`, скрипт предлагает создать их автоматически
- Логика привязки к IP улучшена

</details>

<details>
<summary><b>1.0.5 от 14.06.2026</b></summary>

- Изменены значения тюнинга по умолчанию:
  - `tg_connect = 30` (было 10)
  - `client_handshake = 90` (было 15)
  - `client_keepalive = 120` (было 60)
- Параметры тюнинга всегда можно изменить в настройках

</details>

<details>
<summary><b>1.0.4 от 11.06.2026</b></summary>

- Добавлен **Фикс для iOS вариант 1** (TCP keepalive через sysctl)
- Добавлен **Фикс для iOS вариант 2** (MSS + redirect на отдельный порт)
- Исправлена работа с Telemt Panel
- Исправлена работа с голым Telemt (systemd, `/etc/telemt/telemt.toml`)

</details>

## Требования

- Linux с `systemd`
- `nftables` (устанавливается автоматически)
- `curl`
- Права `root`

## Что делает

- Находит **Telemt** автоматически: MTProxyMax, Docker, systemd, локальный процесс
- **Telemt Panel** игнорируется — её конфиги не затрагиваются
- Определяет нужный netfilter hook:
  - `input` — если Telemt работает на хосте / через host network
  - `forward` — если Telemt работает в Docker bridge
- Для Docker bridge предлагает два режима:
  - **Простой режим** — правило только по порту
  - **Точный Docker-режим** — внутренний IP контейнера + watcher
- Применяет **per-client inbound SYN limiter** через nftables — Classic и Smart By-MEKO
- В **Smart By-MEKO** режиме:
  - автоматически распознаёт **iOS** по **TCP SYN fingerprint**
  - отдельно обрабатывает **iOS** и **Other / Android / Desktop**
  - позволяет выбрать действие для non-iOS клиентов:
    - `icmp-host-unreachable` *(по умолчанию)*
    - `reject (tcp reset)`
    - `drop`
  - позволяет **полностью отключить лимит** отдельно:
    - для **iOS**
    - для **Other**
- Безопасно применяет тюнинг Telemt (с бэкапом конфига перед изменениями)
- При удалении может восстановить конфигурацию из сохранённого бэкапа
- **Фикс для iOS вариант 1** — TCP keepalive через sysctl
- **Фикс для iOS вариант 2** — MSS + redirect на отдельный порт *(не нужен при Smart режиме)*
- Ставит systemd-службу с автозапуском

## Советы

- Поставьте реаниматор, на все нажмите Enter — при первой установке по умолчанию предлагается **Smart By-MEKO**, это лучший выбор.
- В 95% случаев всё заводится на Стандартный конфиг + Реаниматор.
- При **Smart режиме** `client_mss = tspu` в конфиге не нужен — лучше закомментировать если есть.
- В новых версиях **Smart By-MEKO** iOS определяется уже не по `TTL + Length`, а по **TCP SYN fingerprint** — это точнее и ближе к оригинальному фикс-скрипту MEKO.
- Если хотите экспериментировать, в **Smart режиме** можно полностью отключить лимит:
  - для **iOS**
  - для **Other / Android / Desktop**
- Если отключаете лимит для **Other**, вы фактически отключаете основную SYN-защиту Smart режима для non-iOS клиентов.
- Управление лимитами Smart режима:
  - `Меню` → `[c] Настройки Smart режима`
- При **Classic режиме** `client_mss = tspu` тоже не работает в большинстве случаев — лучше закомментировать.
- Если есть проблемы с iOS клиентами при Smart режиме — попробуйте **Fix для iOS вариант 1** (keepalive). Его всегда можно мгновенно откатить.
- Если у вас `telemt` в Docker bridge:
  - сначала пробуйте **Точный Docker-режим**
  - если не помогает, используйте **Простой режим** — он надёжнее работает по умолчанию
- Если у вас Double Hop, ставьте реаниматор на входящей ноде. Скрипт скажет, что не находит telemt — это нормально. Просто нажимайте Enter, но укажите правильный порт (обычно 443). Параметры тюнинга можно прописать вручную на принимающей ноде где стоит telemt.
- В последних версиях telemt 3.4.18+ были добавлены функции, которые использует реаниматор — выбирайте что-то одно, либо новые параметры в telemt, либо реаниматор. Но эксперименты никто не отменял.
- Если удаляете реаниматор и выбираете восстановление из бэкапа — все изменения, внесённые в конфиг Telemt после установки реаниматора, будут потеряны.
- При **Smart режиме** для non-iOS по умолчанию рекомендуется **`icmp-host-unreachable`** — этот режим помогает Telegram быстрее переключаться на рабочее соединение и убирает задержку при старте отправки медиа на Android/Desktop.
- Если хотите сменить поведение non-iOS устройств:
  - `Меню` → `[c] Настройки Smart режима`
  - там можно:
    - изменить `Other Rate / Burst`
    - выбрать `Other Action`
    - полностью отключить или включить лимит для `Other`

## Режимы SYN Limiter

MTproxy-reanimation поддерживает два режима — выбрать можно при установке или в любой момент через меню.

### ★ Smart By-MEKO *(рекомендуется)*

> Вдохновлён проектом [MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO) — спасибо автору за идею.

Интеллектуальный режим с автоматическим разделением клиентов.

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
@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 \
@th,224,24 0x10108 @th,320,32 0x4020000 \
reject with tcp reset

# Остальные → строгий лимит → accept
tcp dport PORT tcp flags & (syn | ack) == syn \
meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } accept

# Остальные сверх лимита → ICMP host-unreachable (по умолчанию)
tcp dport PORT tcp flags & (syn | ack) == syn \
reject with icmp type host-unreachable
```

### Новое в v1.1.0 — лимиты можно полностью отключать

Теперь в Smart режиме можно **полностью отключить лимит**:

- для **iOS**
- для **Other**
- или для обеих веток сразу

#### Если отключён лимит iOS

```nft
# iOS по fingerprint → безусловный ACCEPT
tcp dport PORT tcp flags & (syn | ack) == syn \
@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 \
@th,224,24 0x10108 @th,320,32 0x4020000 \
accept
```

#### Если отключён лимит Other

```nft
# Все non-iOS → безусловный ACCEPT
tcp dport PORT tcp flags & (syn | ack) == syn accept
```

> **Внимание:** отключение лимита для `Other` практически отключает защиту Smart режима для Android/Desktop и прочих клиентов.

### Ключевые отличия от Classic

| | Classic | Smart By-MEKO |
|---|---|---|
| **iOS / остальные** | один общий лимит | раздельные ветки по **TCP fingerprint** |
| **При превышении** | DROP → клиент ждёт 3-5 сек | REJECT / ICMP → быстрый fallback |
| **Время подключения** | 10-20 сек | **3-8 сек** |
| **Порты** | один для всех или iOS Fix v2 | **один порт для всех** |
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

Каждый клиентский IP получает **свой независимый bucket**.

**Про IP-адрес в правилах:**
- Если указан IP → правила применяются только к трафику на этот адрес и порт
- Если IP пустой → ко всему входящему трафику на указанный порт
- В Docker bridge режиме внешний IP может не совпадать с destination после NAT

### Пресеты

| Пресет | Режим | Rate | Burst | Action | Описание |
|--------|-------|------|-------|--------|----------|
| **★ Smart** | Smart | iOS: 15/sec / Other: 54/min | 30 / 1 | **icmp-host-unreachable** | Рекомендуется, лимиты можно отключать отдельно |
| **Жёсткий** | Classic | 1/second | 1 | DROP | Строгое ограничение |
| **Средний** | Classic | 1/second | 3 | DROP | Если жёсткий слишком строг |
| **Мягкий** | Classic | 2/second | 5 | DROP | Для серверов с большим числом клиентов |

## Параметры тюнинга

| Параметр | По умолчанию | Описание |
|----------|:---:|-----------|
| `tg_connect` | 30 | Таймаут подключения к Telegram DC |
| `client_handshake` | 90 | Ожидание начального handshake |
| `client_keepalive` | 120 | Ожидание активности клиента |

Все параметры можно изменить в настройках скрипта (пункт `[3]`).

## iOS фиксы

### Вариант 1 — TCP keepalive

Ускоряет обнаружение мёртвых сокетов через `sysctl`.  
Подходит, если iOS-клиенты после закрытия/сна не могут нормально переподключиться.  
Совместим с обоими режимами NFT.

Значения можно менять прямо из меню.  
Перед применением сохраняются исходные системные значения `tcp_keepalive_*`, при откате они восстанавливаются.

По умолчанию: `time=60, intvl=15, probes=3` → обнаружение мёртвого соединения ~105 сек.

### Вариант 2 — MSS + redirect *(только Classic режим)*

Создаёт отдельный порт для iOS (по умолчанию **4443**) с MSS=92 и прозрачным редиректом на основной порт Telemt.

> **При Smart режиме iOS Fix v2 не нужен** — Smart автоматически разделяет iOS и Android на одном порту.

> **Важно (Classic):** если в конфиге Telemt есть `client_mss = ...`, его нужно убрать перед использованием Варианта 2.

В этом режиме Android / Desktop продолжают использовать основной порт, iOS-клиентам нужно заменить **только порт** в ссылке:

```
было:  tg://proxy?server=IP&port=443&secret=...
стало: tg://proxy?server=IP&port=4443&secret=...
```

## Основные команды

```bash
mtpr    # Открыть меню управления
```

### Проверить активную службу

```bash
# Обычный режим и Smart By-MEKO
systemctl status mtpr-syn-limit.service --no-pager

# Точный Docker-режим
systemctl status mtpr-bridge-watch.service --no-pager
```

### Посмотреть текущие nft-правила

```bash
nft list table inet telemt_limit
```

### Посмотреть все правила Reanimation

```bash
nft list ruleset | grep -A20 -B5 mtpr
```

## Если используется MTProxyMax

Тюнинг применяется через штатные команды, без прямого редактирования `config.toml`.

Для отката:

```bash
mtproxymax tune clear tg_connect
mtproxymax tune clear client_handshake
mtproxymax tune clear client_keepalive
mtproxymax restart
```

## Если используется голый Telemt или Docker

Перед изменением `telemt.toml` или `config.toml` создаётся бэкап (`*.mtpr-backup-*`).

Для отката:

```bash
ls /etc/telemt/telemt.toml.mtpr-backup-*
cp /etc/telemt/telemt.toml.mtpr-backup-<timestamp> /etc/telemt/telemt.toml
systemctl restart telemt
```

## Удаление

Из меню: клавиша `u` / `U`

При удалении скрипт предложит:
- восстановить конфигурацию Telemt из бэкапа
- или оставить бэкап на диске для ручного восстановления позже

## Важно

- Скрипт **не трогает** конфиги Telemt Panel
- Скрипт **не является заменой** Telemt или MTProxyMax
- NFT-правила работают на уровне ядра
- В Docker bridge режиме сначала пробуйте **Точный Docker-режим**, если не помогает — **Простой режим**
- При использовании **Fix для iOS вариант 2** (Classic):
  - уберите `client_mss = ...` из конфига Telemt
  - не забудьте открыть iOS-порт в фаерволе
- **Smart By-MEKO** в bridge/precise режиме работает без `ip daddr` контейнера — идентификация iOS идёт по **TCP fingerprint**, этого достаточно
- При смене сетевых параметров лучше сразу пере-применять NFT-правила из меню
- В **Smart By-MEKO** для non-iOS по умолчанию используется **`icmp-host-unreachable`** — это новый рекомендуемый режим для Android/Desktop при проблемах с отправкой медиа
- При необходимости поведение Smart можно менять через `Меню` → `[c]`
  - менять `iOS Rate / Burst`
  - менять `Other Rate / Burst`
  - выбирать `Other Action`
  - включать / отключать лимит отдельно для iOS и Other
- В **Smart By-MEKO** лимиты можно полностью отключать отдельно для:
  - `iOS`
  - `Other / Android / Desktop`
- Если отключить лимит для `Other`, защита от избыточных SYN для non-iOS клиентов по сути перестаёт работать

---

## Благодарности

- **[MTPROTO-FIX-By-MEKO](https://github.com/Mekotofeuka/MTPR-FIX-By-MEKO)** — идея Smart режима: разделение iOS/Android по TCP fingerprint и использование быстрого REJECT вместо классического DROP

---

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
