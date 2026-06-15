# MTproxy-reanimation

**MTproxy-reanimation** — утилита для серверов с **Telemt / MTProxyMax**, которая помогает стабилизировать первичное TCP-подключение клиентов с помощью **inbound SYN limiter через nftables** и применяет базовый безопасный тюнинг Telemt. За основу взят мануалы сообщества https://h1de0x.github.io/telemt-tune https://assyoucandy.github.io/telemt-server-guide/ https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html

## Обновление

В версии 1.0.4 добавлены фиксы для iOS, рекомендуется попробовать вариант 2 , и перевести клиентов iOS на другой порт как в инструкции. если стоковые варианты не работают, надо пробовать другие значения. Удачи всем ! 

1.0.5 Сообщество говорит, что значения ниже лучше стоковых 10/15/60, изменил по умолчанию при установке на:
tg_connect = 30
client_keepalive = 90
client_handshake = 120
Параметры "Тюнинга" вы всегда можете поменять в настройках. Пробуйте и делитесь опытом в https://t.me/telemtrs

## Установка и обновление 

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/install.sh | sudo bash
```

После установки запускается мастер настройки. Или обновленное меню если ставите поверх установленного.
Если нужно открыть меню позже:

```bash
mtpr
```

## Требования

- Linux с `systemd`
- `nftables` (устанавливается автоматически если отсутствует)
- `curl`
- Права `root`

## Что делает

Скрипт:

- автоматически находит установленный **Telemt** в одном из вариантов:
  - **MTProxyMax** — через `/opt/mtproxymax/settings.conf`
  - **Docker-контейнер** — по имени контейнера и маунтам
  - **Локальный процесс** — через `systemd` или аргументы процесса
  - **Telemt Panel** намеренно **игнорируется** — скрипт не трогает её конфиги
- определяет нужный netfilter hook автоматически:
  - `input` — если Telemt работает на хосте или через `--network host`
  - `forward` — если Telemt работает в Docker bridge
- применяет **per-client inbound SYN limiter** через `nftables`
- может безопасно применить базовые параметры Telemt(потом модно изменить в настройках):
  - `tg_connect = 30`
  - `client_handshake = 90`
  - `client_keepalive = 120`
- перед изменением `config.toml` **создаёт бэкап** (`*.mtpr-backup-*`)
- умеет поставить `systemd`-службу и включить автозапуск
- позволяет управлять всеми настройками через меню

## Принцип работы

Основной метод — **ограничение входящих SYN-пакетов отдельно для каждого IP клиента**.

Используется логика вида:

```nft
tcp dport <PORT>
tcp flags & (syn | ack) == syn
meter { ip saddr timeout 60s limit rate over 1/second burst 1 packets }
counter drop
```

Каждый клиентский IP получает **свой независимый bucket** — один шумный клиент не мешает остальным.

Это помогает на серверах, где у части клиентов:
- долго устанавливается TCP-соединение
- Telemt периодически зависает на первом этапе подключения
- появляются плотные пачки `Telegram handshake timeout`

## Основные возможности

В меню доступны:

- применение NFT-правил
- применение тюнинга Telemt
- настройка IP / порта / rate / burst / timeout
- готовые пресеты:
  - **жёсткий** — `1/second burst 1` *(рекомендуется)*
  - **средний** — `1/second burst 3`
  - **мягкий** — `2/second burst 5`
- свой вариант rate/burst
- просмотр счётчика дропов в реальном времени
- установка / удаление `systemd`-службы (автозапуск при загрузке)
- добавление правил на дополнительные порты
- ручное указание пути к `config.toml` если автообнаружение не сработало
- полное удаление скрипта

## Основные команды

### Запуск меню
```bash
mtpr
```

### Проверить установленную службу
```bash
systemctl status mtpr-syn-limit.service --no-pager
```

### Посмотреть текущие nft-правила
```bash
nft list table inet telemt_limit
```

### Следить за счётчиком дропов
```bash
watch -n 2 'nft list chain inet telemt_limit input'
```

### Удалить правило вручную (временно)
```bash
nft delete table inet telemt_limit
```

## Если используется MTProxyMax

Если на сервере установлен **MTProxyMax**, скрипт применяет тюнинг через штатные команды — без прямого редактирования `config.toml`:

```bash
mtproxymax tune set tg_connect 10
mtproxymax tune set client_handshake 15
mtproxymax tune set client_keepalive 60
```

Для отката тюнинга:

```bash
mtproxymax tune clear tg_connect
mtproxymax tune clear client_handshake
mtproxymax tune clear client_keepalive
mtproxymax restart
```

## Если используется голый Telemt или Docker

Скрипт редактирует `config.toml` напрямую через `sed`.  
Перед изменением автоматически создаётся бэкап:

```bash
/etc/telemt/telemt.toml.mtpr-backup-<timestamp>
```

Для отката — восстановите бэкап вручную:

```bash
ls /etc/telemt/telemt.toml.mtpr-backup-*
cp /etc/telemt/telemt.toml.mtpr-backup-<timestamp> /etc/telemt/telemt.toml
systemctl restart telemt
```

Если нужные секции `[general]` или `[timeouts]` отсутствуют в конфиге — скрипт **не создаёт их сам**, а выводит инструкцию для добавления вручную.

## Рекомендуемый старт

Если не знаешь, что выбрать:

1. Запусти мастер установки
2. Оставь preset **жёсткий** (`1/second burst 1`)
3. Дай серверу поработать **10–30 минут**
4. Посмотри счётчик дропов через меню `[5]`

Если счётчик растёт — limiter работает.  
Если клиенты жалуются на проблемы с подключением — попробуй **средний** (`1/second burst 3`).

**Что за что отвечает:**

tg_connect = 10	Базовый таймаут подключения telemt к upstream Telegram DC. Если upstream Telegram отвечает нестабильно, можно попробовать увеличить до 30.

client_handshake = 15	Базовое ожидание начального handshake клиента. Если клиент долго проходит начальное подключение, можно попробовать увеличить до 120.

client_keepalive = 60	Базовое ожидание активности клиента. При мобильной сети, NAT и нестабильных соединениях можно попробовать увеличить до 90.


**Вариант для тюнинга:**

если базовые значения не помогают, можно попробовать tg_connect = 30, client_handshake = 120, client_keepalive = 90. Это не обязательные значения, а запасной вариант для проблемных сетей.

**Варианты:**

1/second burst 1	Предпочтительный рабочий вариант. Жёсткий per-client режим для входящих SYN. Использовать как основной вариант, если подключение клиента к telemt нестабильно у некоторых провайдеров.

1/second burst 3	Если отдельным клиентам не хватает совсем короткого burst, но хочется сохранить rate 1/sec.

2/second burst 5	Более мягкая альтернатива для сервера с большим числом клиентов.

METER_TIMEOUT=30s	Быстрее очищать состояние per-IP meter.

METER_TIMEOUT=120s	Дольше помнить IP, если клиенты часто ретраят с паузами.

## Удаление

Полное удаление из меню:

```text
u / U
```

Или вручную:

```bash
systemctl disable --now mtpr-syn-limit.service
nft delete table inet telemt_limit 2>/dev/null || true
rm -f /usr/local/sbin/mtpr-syn-limit.sh
rm -f /etc/systemd/system/mtpr-syn-limit.service
rm -f /usr/local/bin/mtpr
rm -rf /opt/mtproxy-reanimation
systemctl daemon-reload
```

Скрипт удаляет только свои файлы.  
Бэкапы конфигов (`*.mtpr-backup-*`) остаются на месте.  
Тюнинг Telemt **не откатывается автоматически** — см. раздел выше.

## Важно

- Скрипт **не трогает** конфиги **Telemt Panel** (`/etc/telemt-panel/`)
- Скрипт **не является заменой** Telemt или MTProxyMax
- NFT-правила работают на уровне ядра и не зависят от Telemt
- При смене порта в MTProxyMax — перезапустите службу: `systemctl restart mtpr-syn-limit.service`

---

Проект: [Liafanx/MTproxy-reanimation](https://github.com/Liafanx/MTproxy-reanimation)
