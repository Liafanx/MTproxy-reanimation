# MTproxy-reanimation

**MTproxy-reanimation** — утилита для серверов с **Telemt / MTProxyMax**, которая помогает стабилизировать первичное TCP-подключение клиентов с помощью **inbound SYN limiter через nftables** и применяет базовый безопасный тюнинг Telemt. За основу взят https://h1de0x.github.io/telemt-tune

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main/install.sh | sudo bash
```

После установки запускается мастер настройки.  
Если нужно открыть меню позже:

```bash
mtpr
```

## Что делает

Скрипт:

- автоматически пытается найти установленный **Telemt**
  - локально
  - в Docker
  - через **MTProxyMax**
- определяет, какой netfilter hook нужен:
  - `input` — если Telemt работает на хосте / через host network
  - `forward` — если Telemt работает в Docker bridge
- применяет **per-client inbound SYN limiter** через `nftables`
- может безопасно применить базовые параметры Telemt:
  - `tg_connect = 10`
  - `client_handshake = 15`
  - `client_keepalive = 60`
- умеет поставить `systemd`-службу и включить автозапуск
- позволяет управлять настройками через удобное меню

## Принцип работы

Основной метод — **ограничение входящих SYN-пакетов отдельно для каждого IP клиента**.

Используется логика вида:

```nft
tcp dport <PORT>
tcp flags & (syn | ack) == syn
meter { ip saddr timeout 60s limit rate over 1/second burst 1 packets }
counter drop
```

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
  - **жёсткий** — `1/second burst 1`
  - **средний** — `1/second burst 3`
  - **мягкий** — `2/second burst 5`
- просмотр счётчика дропов
- установка / удаление `systemd`-службы
- добавление правил на дополнительные порты
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
nft list ruleset
```

### Посмотреть правило лимитера
```bash
nft list table inet telemt_limit
```

### Удалить правило вручную
```bash
nft delete table inet telemt_limit
```

## Если используется MTProxyMax

Если на сервере установлен **MTProxyMax**, скрипт старается применять Telemt-тюнинг через штатные команды:

```bash
mtproxymax tune set tg_connect 10
mtproxymax tune set client_handshake 15
mtproxymax tune set client_keepalive 60
```

Это безопаснее, чем ручное редактирование `config.toml`.

## Рекомендуемый старт

Если не знаешь, что выбрать — начинай с:

- preset: **жёсткий**
- `timeout`: `60s`

То есть:

- `rate = 1/second`
- `burst = 1`

Если это слишком жёстко — пробуй **средний**.

Параметр	За что отвечает
tg_connect = 10	Базовый таймаут подключения telemt к upstream Telegram DC. Если upstream Telegram отвечает нестабильно, можно попробовать увеличить до 30.
client_handshake = 15	Базовое ожидание начального handshake клиента. Если клиент долго проходит начальное подключение, можно попробовать увеличить до 120.
client_keepalive = 60	Базовое ожидание активности клиента. При мобильной сети, NAT и нестабильных соединениях можно попробовать увеличить до 90.
Вариант для тюнинга: если базовые значения не помогают, можно попробовать tg_connect = 30, client_handshake = 120, client_keepalive = 90. Это не обязательные значения, а запасной вариант для проблемных сетей.

Вариант	Когда пробовать
1/second burst 1	Предпочтительный рабочий вариант. Жёсткий per-client режим для входящих SYN. Использовать как основной вариант, если подключение клиента к telemt нестабильно у некоторых провайдеров.
1/second burst 3	Если отдельным клиентам не хватает совсем короткого burst, но хочется сохранить rate 1/sec.
2/second burst 5	Более мягкая альтернатива для сервера с большим числом клиентов.
METER_TIMEOUT=30s	Быстрее очищать состояние per-IP meter.
METER_TIMEOUT=120s	Дольше помнить IP, если клиенты часто ретраят с паузами.

## Удаление

Полное удаление доступно из меню по клавише:

```text
u / U
```

Скрипт удаляет:
- nftables-правила
- systemd-службу
- свои файлы
- симлинк команды `mtpr`

## Важно

Скрипт **не является заменой Telemt или MTProxyMax**.  
Он только добавляет:
- входной SYN limiter
- базовый сетевой тюнинг
- удобное управление этим всем

---

Проект: [Liafanx/MTproxy-reanimation](https://github.com/Liafanx/MTproxy-reanimation)
