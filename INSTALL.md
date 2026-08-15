# Первая установка

Требования:

- Ubuntu 24.04
- доступ `root` или `sudo`
- не менее 1.5 GB RAM и 3 GB свободного места
- два домена, уже направленные на сервер
- возможность открыть `80/tcp`, `443/tcp` и `443/udp` во внешнем firewall провайдера VPS
- доступность внешней API-панели с сервера
- HTTPS URL опубликованного `release.json` из GitHub Release installer

## Что подготовить заранее

Обязательно:

- webhook-домен, например `hooks.example.com`
- домен кабинета, например `app.example.com`
- токен Telegram-бота
- username Telegram-бота
- ID администраторов
- URL внешнего API
- API key
- secret key
- webhook secret Remnawave

Installer автоматически генерирует и не просит вводить:

- пароль PostgreSQL
- secret Telegram webhook
- bootstrap token Web API
- JWT secret Cabinet

Все четыре значения независимы и сохраняются только в приватных служебных
файлах с правами `600`.

## Запуск

```bash
cd /path/to/installer
sudo bash bot-menu.sh
```

Перед первой установкой рекомендуется сначала выполнить:

```text
Установка -> Проверка сервера
```

Потом выбрать:

```text
Установка -> Полная установка
```

Для первой установки выберите новый, ещё не существующий `PROJECT_ROOT`.
Существующий каталог принимается только когда внутри уже есть валидный
`state/install.state` от предыдущей установки; installer не удаляет произвольные
пользовательские каталоги при cleanup.

Во время установки система:

1. проверит сервер
2. установит базовые host tools, необходимые для проверки release
3. проверит Release Bundle, точные Bot/Cabinet SHA, image digests и Cabinet artifact
4. соберёт основные настройки
5. определит текущий SSH-порт и включит базовый профиль UFW
6. создаст рабочие конфиги
7. скачает репозитории и проверит точные HEAD
8. активирует готовый Cabinet artifact без сборки frontend на VPS
9. запустит бота, Postgres и Redis
10. создаст и применит конфиг Caddy
11. зарегистрирует Telegram webhook, если включён webhook-режим
12. установит версионированную management-копию в `/opt/bedolaga-installer`
    и launcher `/usr/local/bin/vpn`

При повторной полной установке installer создаёт recovery snapshot до изменения
настроек, generated files, repositories или runtime. Успех фиксируется только
после health checks. При обратимой ошибке прежний runtime восстанавливается и
проверяется; если это невозможно, Bot останавливается, а точный следующий шаг
сохраняется в `<PROJECT_ROOT>/state/last-runtime-change.json`.

Базовый профиль UFW разрешает текущий SSH-порт, `80/tcp`, `443/tcp` и
`443/udp`, запрещает прочие входящие соединения и оставляет исходящие
соединения разрешёнными. Существующие правила не сбрасываются. Перед первым
изменением копия конфигурации сохраняется в
`<PROJECT_ROOT>/state/firewall-backups/`.

Порты Bot API, PostgreSQL и Redis в UFW не открываются: Bot API привязан к
`127.0.0.1`, а базы доступны только внутри Docker-сети.
Bot container работает как UID/GID `1000:1000`; installer заранее создаёт и
назначает ему только writable data, logs и uploads.

## Итоговый environment

`<PROJECT_ROOT>/state/bot.env` содержит минимальный production profile:

- Telegram Bot в режиме webhook
- PostgreSQL и Redis
- Remnawave API и подписанные Remnawave webhooks
- Web API
- Cabinet в режиме Mini App

Настройки платёжных провайдеров и других опциональных функций не копируются в
`bot.env`. Пока они не настроены отдельно, Bot использует свои встроенные
defaults.

Дополнительные пользовательские переменные хранятся отдельно:

```text
<PROJECT_ROOT>/state/bot.override.env
```

Этот файл загружается после минимального `bot.env` и имеет более высокий
приоритет. Повторная генерация базовой конфигурации его не перезаписывает.

## Что проверить после установки

Рекомендуемый порядок:

- `Обслуживание -> Статус`
- `Обслуживание -> Диагностика`
- `Обслуживание -> Firewall -> Проверить защиту`
- `Обслуживание -> Домены и Caddy -> Проверка SSL и доменов`

Ожидаемый результат:

- `https://hooks.example.com/` отвечает `404` (default deny)
- `https://hooks.example.com/remnawave-webhook` подтверждает включённый webhook
- `https://app.example.com/` открывает кабинет
- `https://app.example.com/api/cabinet/branding` отвечает

После установки исходный clone больше не нужен для обслуживания: используйте
`sudo vpn`. Удаление выбранного stack не удаляет эту команду.
