# PostgreSQL 15 → 18 в Installer

Этот механизм относится к Installer-managed установке с локальным PostgreSQL.
Исходники, API и Alembic migrations Upstream Bot остаются неизменными.
Наличие кода и локальных tests не означает готовый опубликованный Release.
Новый image/Installer source требуют полного Ubuntu 24.04 lifecycle и отдельного
перехода с предыдущего Bundle до публикации и production.

## Порядок переноса

1. **В Installer:** выбрать проверенный Release Bundle с PostgreSQL 18 через
   существующее обновление Release Bundle. Версия определяется из `PG_MAJOR`
   точного Docker image, включая digest references. Текущий Bundle с PG15
   продолжает использовать PG15; один новый Installer не переключает базу.
2. **До остановки Bot:** проверить текущие image/engine/volume/mount и место
   отдельно на дисках state и Docker. Запас учитывает dump, проверочное
   восстановление и новую базу. Несовпадение или нехватка места прекращают перенос.
3. **В Protected Update:** остановить Bot и подтвердить остановку, создать dump
   и проверить его восстановлением во временную БД. Сохранить количество строк
   каждой application table и `last_value`/`is_called` каждой sequence.
4. **В Docker:** создать отдельный volume для этой попытки, запустить только
   PostgreSQL 18, восстановить dump и сверить таблицы и sequences. PostgreSQL 18
   использует `/var/lib/postgresql`; старый PG15 volume остаётся на месте.
   Bot запускается после успешной сверки. Ресурсы другого Compose project
   и уже существующий target volume использовать запрещено.
5. **При commit:** сохранить major и active volume в `state/install.state`.
   Повторный render, настройки и recovery сохраняют эти значения. Рядом с dump
   сохраняются private `.postgres-upgrade.txt` receipt и manifests сверки.
   Старый PG15 state без новых ключей продолжает означать прежнее хранилище PG15.

`POSTGRES_MAJOR` и `POSTGRES_VOLUME_NAME` — metadata Installer, а не новые
настройки Upstream Bot. Compose volume key выводится из проверенного имени;
обычная изоляция через `--project-name` сохраняется.

## Отказ и восстановление

До commit защищённое обновление возвращает прежние image/volume/configuration,
восстанавливает проверенный dump и проверяет базу перед возвратом Bot.
При непроверенном восстановлении стек остаётся остановленным с durable marker.
Используйте существующее восстановление прерванного Protected Update;
не запускайте незавершённый apply повторно вручную. Новая попытка после
проверенного rollback получает другой target volume; том прерванной попытки
не очищается и не используется автоматически.

После commit старый PG15 volume содержит данные только на момент переноса.
Поздний возврат потеряет новые записи и требует отдельного восстановления
актуальных данных. Обычный file backup не содержит PostgreSQL, поэтому file
recovery и snapshots настроек запрещают переключение engine/active volume.
Восстановление потерянного state проверяет существующие Compose и работающий
контейнер; оно не должно угадывать PG15 по старому default.

Сохраните старый volume, dump и внешний полный migration package минимум на
согласованный срок и рабочий цикл. Их удаление не является частью обновления.
Архивы и dumps содержат private данные и хэши паролей: не публикуйте их.

## Проверки

На изолированном Linux:

```bash
bash scripts/run-release-contract-tests.sh
POSTGRES_UPGRADE_DISPOSABLE=true bash tests/integration/postgres-major-upgrade.sh
```

Вторая команда создаёт собственный временный Compose project и удаляет только
его ресурсы. Она проверяет реальные PG15/PG18 engines на синтетической схеме:
две учётные записи, balances, сроки подписок, legacy transaction, строки таблиц,
sequences, возврат старого volume, прерванный target и новую попытку. Значение
`0131` в fixture не является доказательством проверки полной схемы Upstream Bot.
Полный native lifecycle и переход на реальной неизменённой схеме Bot нужны отдельно.

## Источники

- [Официальная инструкция выбранного Upstream Bot SHA](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot/blob/5bda3c56f0afd9f4813e9c6fa48934948b05ebae/docs/postgresql-18-upgrade.md).
- [Оригинальный pg-upgrade.sh](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot/blob/5bda3c56f0afd9f4813e9c6fa48934948b05ebae/scripts/pg-upgrade.sh).
- [Официальные PostgreSQL Docker images](https://github.com/docker-library/docs/blob/master/postgres/README.md).

Upstream `make pg-upgrade` рассчитан на Compose/volumes исходного Bot repository.
Не запускайте его прямо поверх Installer runtime и не заменяйте вручную только
image: здесь перенос выполняется через ownership и Protected Update Installer.
