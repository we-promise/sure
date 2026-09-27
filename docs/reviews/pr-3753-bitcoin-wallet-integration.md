# PR #3753: доработки для интеграции Bitcoin wallets в Sure

Дата анализа: 27.09.2026.

Проверены [PR #3753](https://github.com/we-promise/sure/pull/3753), его актуальный head `fc368bed541b81cf16d0c27b0920d3f32ff087e0` и текущий локальный `main` — `76c5d0a83174b75ccc728400fee9525215f29e24`. База PR — `1052443aab22860b8a05414195912adcdaa04fc2`. Версия head сверена с GitHub API; рассмотренные общие модели расчёта и контроллер holdings в локальном main совпадают с базой PR.

Исходный анализ выполнен через Serena в отдельном временном снимке PR без запуска Rails и тестов. Наблюдения ниже привязаны к исходному head. Последующая реализация выполнена в ветке PR с CodeGraph и Serena; её результат и выполненные проверки приведены отдельно. P1 — доработки до слияния; P2 — завершение интеграции.

Главный вывод: Bitcoin-провайдер должен отвечать за количество и движения одной BTC-позиции. Денежная часть, остальные инструменты, себестоимость, история и графики должны обрабатываться общими механизмами Sure. Простое удаление нового расчёта недостаточно: общий механизм нужно научить совместной работе ручных позиций и позиции, которой управляет провайдер.

## Результат реализации

Все 16 пунктов реализованы в ветке PR. Ниже сохранены исходные наблюдения по head `fc368bed`; отмеченные пункты закрыты последующими изменениями.

- Отдельный `BitcoinWalletAccount::Portfolio` удалён. BTC публикует только свою позицию; cash, остальные holdings и история проходят общие materializers.
- Общий контракт position-only адаптеров, cash anchors и provider cash capture сохраняет ручную часть и не позволяет старым провайдерам перезаписать смешанный портфель.
- Дерево Sync включает discovery checkpoints, retries, cancellation и account child sync. Семейная дата едина; активный account sync получает follow-up при новых данных.
- Проверены FX/custom rate, split, basis unknown/locks, valuations, backdated edits, удаление/remap, manual tracking после disconnect, chart history, full-provider snapshots, RBF/reorg и смена источников.
- Управляемое количество защищено; Preview off сохраняет обычный account sync. UI использует automatic polling, conditional HD inputs, confirmed/pending, stale/error states и ограничение списка адресов.
- Две additive Rails 8.1 миграции добавляют `valuations.cash_entry_total` и `valuations.superseded_at`; существующие счета не переводятся в новый режим автоматически.

Верификация в изолированных Docker-контейнерах, без личных счетов и production БД:

- Full Rails: **10 127 runs, 42 628 assertions, 0 failures, 0 errors, 33 существующих условных skips**.
- Full Chromium system: **166 runs, 843 assertions, 0 failures, 0 errors**.
- Дополнительный integration/holding-прогон, включая годовую историю и приоритет position owner: **82 runs, 281 assertions, 0 failures, 0 errors**. Idle sync сохраняет прежние строки; backdated правка пересчитывает только затронутый диапазон.
- Ruby lint, ERB lint (748 шаблонов), Biome (133 файла) и Brakeman (**0 security warnings**) прошли.
- После CI-падения на кратковременном flash browser assertions проверяют постоянное состояние подключения/отключения, сохранённую позицию и доступность ручных действий. Сфокусированный прогон: **3 runs, 18 assertions, 0 failures, 0 errors**; исходный полный system-прогон выше предшествовал усилению этих assertions.
- Публичные fixture-скриншоты обновлены; CodeGraph использован для scoped impact exploration, Serena — для focused symbols и правок. Динамические Rails связи проверены по source/schema/tests.

Дополнительное ревью подтвердило гонки concurrent wallet sync: разные parents теперь получают независимые children, running read не поглощает source edits, а занятый advisory lock создаёт deferred child вместо преждевременного completion. Замечание CodeRabbit о `CurrentPositions` подтверждено отдельным red/green тестом: position owner имеет приоритет перед более новой строкой complete provider. Контракты затронутых методов документированы для pre-merge Docstring Coverage.

## P1: до слияния

- [x] **1. Встроить BTC в общий механизм материализации.** [Account::Syncer][account_syncer] при подключённом wallet вызывает `BitcoinWalletAccount::Processor` и выходит до `Balance::Materializer`; [Portfolio][portfolio] самостоятельно записывает holdings, дневные balances и итог счёта. Это второй финансовый расчёт со своими правилами. Доработка: оставить wallet-процессору импорт BTC, а выбор authoritative holdings по инструменту, расчёт прочих позиций и общего баланса реализовать в `Holding::Materializer` / `Balance::Materializer`. Область ответственности провайдера должна описываться общей возможностью, а не проверками `bitcoin_wallet_account` в нескольких моделях. Проверка: счёт BTC + другой актив + cash проходит один согласованный расчёт при wallet sync, account sync, импорте и обновлении цены.

- [x] **2. Применять валютную конвертацию проводок — уже найденная проблема.** В [Portfolio#materialize][portfolio] используется `entries.sum(&:amount)` без перевода валюты и без `Trade#exchange_rate`. Расход €100 на USD-счёте уменьшает cash на число 100 даже при курсе 1.10, вместо $110. Общий [Balance::SyncCache#converted_entries][sync_cache_entries] переводит суммы по дате операции, учитывает пользовательский курс и диагностирует отсутствующие курсы. Доработка: использовать этот общий путь для cash и потоков. Проверка: иностранная операция, ручной курс сделки и отсутствующий курс дают такое же поведение, как в обычном Sure.

- [x] **3. Исключать родителей split-транзакций — уже найденная проблема.** Новый запрос применяет `excluding_pending`, но не `excluding_split_parents`. Родитель на 100 и две части на 40 и 60 могут дать расход 200. Общий [SyncCache][sync_cache_entries] исключает родителей. Доработка: применять общий набор фильтров ко всем расчётам cash и flows. Проверка: split и его последующее изменение учитывают общую сумму один раз.

- [x] **4. Сохранять правила себестоимости остальных активов — уже найденная проблема.** [persist_manual_holdings][manual_holdings] записывает только `qty`, `price`, `amount`. Оно не применяет `Holding::CostBasisReconciler`, не сохраняет новую calculated basis и не очищает прежнюю calculated basis, когда входящий transfer делает стоимость неизвестной. Эти правила, приоритеты manual/provider/calculated и блокировка ручной стоимости реализованы в [Holding::Materializer][holding_materializer]. Доработка: повторно использовать общий механизм сохранения. Проверка: покупка, продажа, входящий transfer, locked basis и разблокировка дают стандартную себестоимость и состояние unknown.

- [x] **5. Учитывать Valuation и изменения истории относительно baseline.** [Portfolio][portfolio] исключает все `Valuation`, начинает расчёт с `baseline_cash_balance` и не использует `window_start_date`. В день подключения ранее созданные операции исключаются по `created_at`; их последующая правка не делает их новыми. Операции с датой до baseline также не входят в расчёт. Общий [ForwardCalculator][forward_calculator] учитывает абсолютные оценки. Доработка: определить общий anchor для гибридного счёта и пересчитывать затронутый диапазон, сохранив правила оценки всего счёта и cash. Проверка: reconciliation после подключения, правка операции в день подключения и backdated импорт отражаются в балансе без повторного включения исходного cash.

- [x] **6. Корректно переносить и переоценивать другие holdings.** [latest_other_holdings / fill_untraded_positions][other_holdings] берут последнюю позицию на сегодня и заполняют ею отсутствующие дни вплоть до baseline, даже если исходная позиция появилась позднее. Уже существующая дневная строка пропускается, поэтому новая котировка не переоценивает её. Выборка ограничена валютой счёта; holdings в другой валюте без trade-журнала могут выпасть. Созданный перенос не копирует `account_provider_id`, `cost_basis_locked` и `security_locked`. [current_holdings][current_holdings] дополнительно выбирает последнюю строку каждого инструмента без учёта состава последнего снимка другого провайдера. Доработка: переносить позиции по состоянию на конкретную дату, учитывать источник/валюту, нулевые позиции и границы provider snapshot; использовать общую политику переоценки. Проверка: новый актив не возникает в прошлом, проданный актив не остаётся текущим, цена обновляется, provenance и locks сохраняются.

- [x] **7. Согласовать удаление и remap holdings с областью BTC-провайдера.** Новый [can_delete_holding?][deletion_permission] разрешает удалить BTC-строку до baseline. Но [Holding#destroy_holding_and_entries!][holding_delete] удаляет все сделки этого инструмента на счёте, включая более поздние wallet trades и reconciliation. При удалении другого ручного актива остаются старые holdings, из которых новый перенос может снова создать текущую позицию. [remap_security!][holding_remap] переносит holdings и trades, но не обновляет `wallet.security_id`; следующий sync продолжает публиковать прежний инструмент. Доработка: проверять полный объём удаления, очищать нужную серию ручного актива и либо запрещать remap управляемого BTC, либо атомарно менять его привязку. Проверка: удаление старой BTC-строки не уничтожает управляемый журнал; удалённый ручной актив не возвращается; remap не создаёт две BTC-позиции.

- [x] **8. Сохранить историю на графиках.** PR исключает wallet из специальной логики `Account#history_start_date`, но [Account::Chartable][chartable] продолжает вызывать [LinkedInvestmentSeriesNormalizer][series_normalizer]. Тот обрезает историю linked investment-счёта по первым provider entries/holdings; новый BTC reconciliation имеет `source`, а BTC holding — provider id. Поэтому сохранённая в БД ручная история может исчезнуть из графика после подключения. Доработка: согласовать нормализацию индивидуальных и агрегированных графиков с частичным управлением портфелем. Проверка: ранее сохранённые точки остаются видимыми до и после connect/disconnect, включая агрегированный sparkline.

- [x] **9. Разделить подключение позиции и управление всем счётом в UI.** Добавление `AccountProvider` делает весь счёт `linked?`. В [activity feed][activity_feed] для linked Crypto скрывается меню ручных действий, включая transfer и valuation; форма счёта скрывает баланс. Это мешает заявленному сохранению ручного учёта cash и остальных активов. Кроме того, [HoldingsController#sync_prices / remap_security][holdings_controller] напрямую запускают обычный `Balance::Materializer` со стратегией reverse, обходя wallet-ветку `Account::Syncer`. Доработка: использовать возможности провайдера по позиции и единый вход в пересчёт, сохранить разрешённые ручные действия и существующие права доступа. Проверка: на подключённом mixed-счёте доступны ручные операции; обновление цены другого актива не переключает правила всего счёта.

- [x] **10. Включить wallet sync в общий жизненный цикл Sync.** [OnchainWalletItem::Syncer][item_syncer] просто ставит `BitcoinWalletSyncJob` в очередь; wallet не создаёт дочерний `Sync`. Семейная задача может завершиться до публикации BTC, ошибки wallet не определяют её результат, отмена не распространяется на него. Задача wallet вызывает Processor напрямую и не проходит `Account::MarketDataImporter`, post-sync и стандартные broadcasts. Для wallet-only connection семейная синхронизация также не планирует обычный account sync: счёт уже не manual, а `linked_accounts` у item содержит только legacy accounts. Доработка: связать чтение wallet с parent Sync и последующей синхронизацией счёта, переиспользовать состояния, отмену, статистику и уведомления. Проверка: family/manual/hourly sync ждут BTC, показывают его ошибки, обновляют цены прочих активов и интерфейс.

- [x] **11. Согласовать отсутствие котировки с общей ценовой политикой.** [Portfolio.price][wallet_price] ищет только `Security::Price` и FX; вызывающие места заменяют отсутствие цены на 0. При отсутствии market quote уже известная цена из ручной сделки/holding не используется, хотя общий [Holding::PortfolioCache][portfolio_cache] умеет брать такие цены. Доработка: использовать согласованные источники цены и диагностику отсутствующей оценки; отдельно показывать freshness on-chain quantity и market valuation. Не представлять отсутствие котировки как установленную нулевую стоимость. Проверка: отключённый price provider, ручная BTC-позиция и отсутствующий FX не приводят к необъяснимому обнулению оценки.

- [x] **12. Использовать общие правила cash/non-cash flows и корректировок.** В [Portfolio][portfolio] любой обычный Trade даёт non-cash flow по `entry.amount`, даже если `qty == 0`: дивиденд $5 создаёт лишний non-cash outflow $5 и соответствующее изменение market flows. Общий [BaseCalculator][base_calculator] выделяет такие события как cash-only. Wallet reconciliation всегда даёт flow 0; после первого дня изменение количества из такой корректировки попадает в `net_market_flows`, хотя цена могла не измениться. Доработка: добавить в общий расчёт явную семантику cash-neutral asset transfer и quantity adjustment, сохранить обработку income trades. Проверка: дивиденд не уменьшает активы, а изменение охвата источников или восстановление количества не выглядит рыночной прибылью.

## P2: завершить интеграцию

- [x] **13. Закрыть полный цикл reorg и восстановления baseline-транзакции.** [Processor#materialize_movements][movements] создаёт `_reversal` для пропавшей baseline-транзакции, но при её возвращении пропускает `baseline && present` и не обрабатывает прежнюю reversal. Общий quantity reconciliation может восстановить текущее количество, поэтому это не утверждение о неверном текущем балансе. Требуется проверить журнал, provenance и flows полного цикла. Доработка: явно определить отмену/компенсацию reversal и закрепить идемпотентность. Проверка: baseline TX → исчезновение → возвращение, повторные sync, reconnect и смена источников сохраняют верное количество и объяснимую историю.

- [x] **14. Унифицировать проверки занятого адреса с legacy on-chain.** [BitcoinWalletAddress#conflicts?][address_conflicts] проверяет все legacy `onchain_wallet_accounts` семейства без фильтров active/linked, тогда как [Family#onchain_address_linked?][address_linked] проверяет активные подключённые legacy записи. Старая отвязанная запись может мешать новому wallet. Доработка: использовать единое понятие реально занятого адреса, сохранить ограничения БД для grouped wallets и учитывать гонки с legacy create. Проверка: активный дубликат блокируется, отвязанный legacy-адрес можно подключить, два конкурентных подключения не создают двойной учёт.

- [x] **15. Доработать состояние подключения и повторного sync в интерфейсе.** [show][wallet_view] показывает одно суммарное количество, общую ошибку и polling только для discovery; `stale?` и отличие confirmed/pending не объясняются. `connect!` проверяет наличие `last_synced_at`, но не свежесть результата. [Adapter#sync_path][adapter_sync_path] ведёт в контроллер с Preview-гейтом: после выключения Preview обычный refresh адаптера становится недоступен, хотя фоновые обновления продолжаются. Доработка: оставить управление источниками за gate, а обновление уже подключённой позиции направить через обычный разрешённый sync; показать stale/pending, progress и понятные причины AddressMismatch/Conflict; обновлять результат без ручного Refresh. Поля xpub и gap limit показывать только для HD-источника, список адресов ограничить/пагинировать. Проверка: Preview off сохраняет рабочий sync; старый preview требует актуализации; большие адресные списки и ошибки удобны на узком экране.

- [x] **16. Завершить оптимизацию пересчёта длинной истории.** SQL-чтения внутри дневного цикла уже существенно сокращены; это исправление не нужно повторять. Но [Portfolio][portfolio] пересчитывает весь диапазон от baseline, запускает ForwardCalculator от начала истории счёта и для каждого дня фильтрует все `@holdings.values`. Это даёт примерно квадратичный обход истории по дням и долго удерживает account lock; существующий тест сравнивает только число SELECT. Доработка: использовать общий incremental window, индекс holdings по дате, пакетное сохранение и агрегированные counts вместо загрузки всех addresses на Accounts/API. Проверка: годовой mixed-портфель, idle sync и одна backdated правка имеют ограниченные время, число записей и длительность блокировки.

## Реализованное поведенческое покрытие

Существующие проверки публичных BIP84-векторов, точности сатоши, change/batching, pending/RBF/reorg, шифрования и ошибок чтения сохранены. Дополнительные сценарии проверены в [integration tests](../../test/models/bitcoin_wallet_account/integration_test.rb), [sync lifecycle tests](../../test/models/bitcoin_wallet_account/sync_lifecycle_test.rb), [controller tests](../../test/controllers/bitcoin_wallets_controller_test.rb) и [system tests](../../test/system/bitcoin_wallets_test.rb):

- [x] Датированный FX, пользовательский курс сделки, split и стандартная обработка valuation.
- [x] Себестоимость остальных активов, unknown/locks, иностранные holdings, новый актив после baseline, удаление и переоценка.
- [x] Правки денежных операций до подключения, backdated импорт и публичный reconciliation workflow.
- [x] Parent/child completion, failure, retries, discovery checkpoints, cancellation и единая семейная дата.
- [x] Защита ранних BTC-строк и managed quantity/remap, удаление ручного актива и manual tracking после disconnect.
- [x] Индивидуальные и агрегированные графики сохраняют историю до подключения.
- [x] Возвращение baseline TX после reorg, RBF между датами и пересогласование охвата источников без ложной прибыли.
- [x] Management authorization, чужие source IDs и обычный account sync с Preview off.
- [x] Browser flow через Accounts menu, автоматический discovery polling, условные HD inputs, disconnect и узкий экран.
- [x] Годовая история, idle sync и backdated правка сохраняют строки вне окна пересчёта.
- [x] Полный репозиторный pre-PR checklist выполнен в изолированном Docker-окружении.

## Что сохранить при переработке

В актуальном head уже исправлены атомарное создание prerequisites, сетевые чтения вне row-lock transaction, лишний перечитанный HD lookahead, обход pending child/grandchild spends и каскадное удаление дочерних wallet-таблиц. Сохранить эти исправления, шифрование xpub, фильтрацию ключей, безопасный status API, family/account authorization, точность сатоши и нулевые cash amounts у BTC transfers.

Рекомендуемый порядок: общий контракт частичного провайдера и материализация → FX/split/basis/anchors/flows → мутации holdings и графики → дерево Sync → UI, жизненный цикл источников и производительность. Пункты 2–12 проверяют конкретные последствия основного архитектурного изменения и должны стать его приёмочными сценариями.

[account_syncer]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/account/syncer.rb#L20
[portfolio]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_account/portfolio.rb#L15
[sync_cache_entries]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/balance/sync_cache.rb#L74
[manual_holdings]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_account/portfolio.rb#L159
[holding_materializer]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/holding/materializer.rb#L85
[forward_calculator]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/balance/forward_calculator.rb#L18
[other_holdings]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_account/portfolio.rb#L174
[current_holdings]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/account.rb#L586
[deletion_permission]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/account/linkable.rb#L100
[holding_delete]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/holding.rb#L88
[holding_remap]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/holding.rb#L148
[chartable]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/account/chartable.rb#L11
[series_normalizer]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/balance/linked_investment_series_normalizer.rb#L94
[activity_feed]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/components/UI/account/activity_feed.html.erb#L7
[holdings_controller]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/controllers/holdings_controller.rb#L56
[item_syncer]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/onchain_wallet_item/syncer.rb#L15
[wallet_price]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_account/portfolio.rb#L82
[portfolio_cache]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/holding/portfolio_cache.rb#L95
[base_calculator]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/balance/base_calculator.rb#L89
[movements]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_account/processor.rb#L65
[address_conflicts]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/bitcoin_wallet_address.rb#L18
[address_linked]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/family/onchain_wallet_connectable.rb#L39
[wallet_view]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/views/bitcoin_wallets/show.html.erb#L1
[adapter_sync_path]: https://github.com/vlnd0/sure/blob/fc368bed541b81cf16d0c27b0920d3f32ff087e0/app/models/provider/bitcoin_wallet_adapter.rb#L20
