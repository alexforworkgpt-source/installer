# Выпуск дизайна Custom Cabinet — 2026-10-03

Status: **STABLE / PACKAGE_READY_WITH_ACCEPTED_LIMITS**. Production: **NOT STARTED**.
Пакет готов к отдельно разрешённому production-переходу по существующему runbook;
сам переход, свежий production baseline и off-host backup в эту задачу не входили.

## Точные версии

| Компонент | Значение |
| --- | --- |
| Release Bundle | [bundle-v2026.10.03.1](https://github.com/alexforworkgpt-source/installer/releases/tag/bundle-v2026.10.03.1), Release ID 402532555; stable, immutable |
| Custom Cabinet | [cabinet-v2026.10.03.1](https://github.com/alexforworkgpt-source/custom-cabinet/releases/tag/cabinet-v2026.10.03.1), Release ID 402533176; stable, immutable |
| Cabinet source / tree | `3b6255597f5ad5270136dd1f683fed980b925a66` / `8422dc4a2ab015b6025200a3f8c417fa912c38de` |
| Installer | `installer-v2026.10.02` / `75c49bec9c2a764e123fc0ef675f8c45fc22a1ab`; прежний stable Release переиспользован |
| Upstream Bot | `v4.15.0` / `877690a7039d1326b2c00eda3e297879b80c0678` |
| Upstream Cabinet | `v1.79.0` / `821c7b71823573a756de00418acb25118ede1c9c` |
| Bundle identity | `b9250c20a6e45b3dd08342e378164e2c9f6b6ee89bbd214a4d226bac86e4494e` |
| Cabinet artifact SHA-256 | `e8a1569f8c23de862b87efc726f14a8247c26327f8bcf2ae4160979845b80a20` |
| Сравнение / rollback reference | предыдущий stable `bundle-v2026.10.02.1` / `cabinet-v2026.10.02.1` |

Manifest для будущего перехода: [конечный URL нового Bundle](https://github.com/alexforworkgpt-source/installer/releases/download/bundle-v2026.10.03.1/release.json).

## Что изменено и проверено

1. **Custom Cabinet:** оплаченная периодическая подписка с привязанным тарифом
   открывает продление того же ID. Trial, daily, limited и явный выбор тарифа
   сохраняют прежние ветки. В Classic показана месячная цена длинных сроков после
   скидки; purchase/renewal используют общие карточки и внешний Card. На renewal
   добавлены группа и иконки, устройства вынесены отдельно, кнопка оплаты следует
   сразу за карточками. Заголовки purchase/renewal различаются по согласованным ключам.
2. **Dashboard:** короткий пробный бейдж использует существующий Gift и цвета
   `#FFC56B / #3A3023 / #74572F`, сохраняя размеры. Первоначальная карточка
   продолжения trial и management action сохранены. Review исправил наложение
   скидки на срок и неверную expired-подсказку активного тарифа; проверки сначала
   падали, затем прошли. API/types/config/dependencies/LICENSE/UPSTREAM не изменены.
3. **Exact source в Linux:** 1006 frontend + 15 publication tests на каждой Node
   24/26, lint/format/type-check/build и CodeQL PASS. В локальном Biome нет ошибок,
   прежние 40 warnings / пять infos сохранены. CodeQL: 32
   прежних открытых alerts, новых относительно начального snapshot нет; успешный
   job не означает отсутствие всех security findings. Audit сохраняет прежнюю
   non-blocking политику. [Publication/source gate](https://github.com/alexforworkgpt-source/custom-cabinet/actions/runs/37127280022).
4. **Браузер:** 117 PASS на source и ещё 117 PASS на независимо скачанном публичном
   artifact; ширины 320/375/768/1024/1280, RU/EN/FA, светлая/тёмная/operator темы.
   Шесть проверок публичной сборки подтвердили trial бейдж, карточку и action.
   Широкий исходный browser suite: 72 PASS, два intentional skips, три старых
   assertions FAIL; те же ошибки воспроизведены на exact stable 8fb8cbe. Отдельная
   временная копия с актуальными ожиданиями decimal labels / selected mobile border
   прошла четыре варианта, сохранив amounts, payload, steps и double-submit checks.
   Это mocked browser evidence; исходный suite не объявляется полностью PASS.
5. **Публичные файлы:** точные наборы двух Cabinet assets и шести Bundle assets,
   API sizes/digests, SHA-256/checksum bytes, source/tag/tree/LICENSE/record/run,
   provenance и безопасные archives PASS. Marker RSA serialization в crypto vendor
   совпадает байт в байт с прежним stable module, ключевого материала в нём нет.
   Bundle publication: 141 contract tests и два одинаковых deterministic builds PASS.
6. **Тестовая Ubuntu 24.04:** новый Bundle установлен из публичного URL; outcome
   committed, три healthy containers, health ok, Cabinet/instructions/branding 200,
   webhook root 404, no-store. Проверены 38 management Installer files. Cleanup и
   postflight PASS, local server.env unchanged. Installer lifecycle переиспользован
   по точному прежнему source/tree/archive и неизменным Bot/images/contracts/OS;
   protected transition NOT_REQUIRED. Полный lifecycle заново не запускался.

## Сохранность и evidence

Сохранены все 43 прежних Installer и 18 Cabinet Releases, их IDs,
notes/assets и существующие tag refs. Metadata promotion сохранил новые candidate
bytes. Latest: Installer `v2026.10.01`, Cabinet `cabinet-v2026.10.02.1`.
Backend, site, GitHub settings и production не изменялись. Owner working files
и HEADs сверены по исходной inventory; release/review выполнялся в чистых копиях.
Review corrections опубликованы в main; старую dirty копию нельзя автоматически
наложить на следующий release source, поскольку она сохранена до этих corrections.

- [Reviewed promotion record](https://github.com/alexforworkgpt-source/installer/blob/c11b729f6b2c70153024aee7e661c89f38eae38c/releases/evidence/design-bundle-2026.10.03.1-promotion.json)
- [Очищенный public integrity / disposable smoke log](https://github.com/alexforworkgpt-source/installer/blob/32c887eede5767e662163651aaa5bbcfc7f086d8/releases/evidence/design-bundle-2026.10.03.1-checks.log)
- [Bundle promotion run](https://github.com/alexforworkgpt-source/installer/actions/runs/37128446943)
- [Ограниченное compatibility evidence](https://github.com/alexforworkgpt-source/custom-cabinet/blob/77f0d15493b70426fe791cf307f48f3d859246b0/releases/evidence/compatibility-design-3b62555-877690a7-20261003.md)

## Ограничения и production readiness

Предыдущие принятые OPEN/BLOCKED ограничения сохранены: Classic auto-purchase,
unused legacy email wrapper, полное response-field parity/authenticated staging,
physical Telegram/accessibility и реальные payment/renewal/concurrency/panel flows.
Ни unit, ни mocked browser, ни успешная fresh installation не закрывают их и не
объявляют полный live PASS. BSCHEKER и Simple/Lite Mode остаются исключёнными.

Release gates завершены; новый блокер выпуска не найден. Production обновлять
только после отдельного разрешения, свежей сверки его state, off-host migration
backup и предусмотренного runbook Protected Update по конечному manifest URL.
Последний зафиксированный production Bundle остаётся `bundle-v2026.10.02.1`;
в этой задаче его текущее состояние заново не проверялось.
