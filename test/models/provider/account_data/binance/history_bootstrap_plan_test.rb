require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Binance::HistoryBootstrapPlanTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Plan = Provider::AccountData::Binance::HistoryBootstrapPlan
  Value = Provider::AccountData::MigrationValue
  Copied = Data.define(:family, :item, :source, :account, :link, :copier, :control, :mapping)
  TIMESTAMP = 1_700_000_000_123

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Binance.expects(:new).never
    BinanceAccount::SecurityResolver.expects(:resolve).never
  end

  test "all posted identities offer separate market and pair maxima while retaining existing financial rows" do
    cache = history(spot: { "BTCUSDT" => [ trade_row(id: 2), trade_row(id: 11) ], "ETHBTC" => [ trade_row(id: 7) ] },
      futures: { "BTCUSDT" => [ trade_row(id: 3) ] }, p2p: [ p2p_row, p2p_row(order: "sell-02", side: "SELL", time: TIMESTAMP + 1000) ])
    with_binance_copy(cache) do |context|
      entries = [ trade(context, "binance_spot_BTCUSDT_2"), trade(context, "binance_spot_BTCUSDT_11"),
        trade(context, "binance_spot_ETHBTC_7"), trade(context, "binance_futures_BTCUSDT_3"),
        *post_p2p(context), *post_p2p(context, order: "sell-02") ]
      entries.first.update!(name: "User correction", amount: 999, user_modified: true, import_locked: true, excluded: true)
      original = entries.map { |entry| [ entry.reload.attributes, entry.entryable.reload.attributes ] }
      counts = [ Entry.count, Trade.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, ProviderSyncCheckpoint.count, Sync.count ]

      result = plan(context)

      assert result.ready?
      assert_equal({ "ids" => { "spot" => { "BTCUSDT" => 11, "ETHBTC" => 7 }, "futures" => { "BTCUSDT" => 3 } },
        "p2p_after" => TIMESTAMP + 1000 }, result.cached_history)
      assert_equal entries.map(&:id).sort, result.document.fetch("rows").flat_map { |row| row.fetch("members").map { |member| member.fetch("entry_id") } }.sort
      assert_equal original, entries.map { |entry| [ entry.reload.attributes, entry.entryable.reload.attributes ] }
      assert_equal counts, [ Entry.count, Trade.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, ProviderSyncCheckpoint.count, Sync.count ]
      assert result.document.frozen?
      assert result.cached_history.fetch("ids").frozen?
      assert result.document.fetch("requires_identity_publication")
      assert result.document.fetch("requires_quiesced_reverification")
      refute result.document.fetch("upstream_history_complete")
      assert context.control.reload.quiescing?
      assert context.control.provider_connection.reload.disabled?
    end
  end

  test "an earlier cached trade without an Entry blocks a higher posted maximum" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row(id: 2), trade_row(id: 900) ] })) do |context|
      posted = trade(context, "binance_spot_BTCUSDT_900")

      result = plan(context)

      refute result.ready?
      assert_nil result.cached_history
      assert_equal [ { "code" => "cached_record_not_posted", "external_id" => "binance_spot_BTCUSDT_2" } ], result.document.fetch("blockers")
      rows = result.document.fetch("rows")
      assert_equal %w[unresolved posted], rows.map { |row| row.fetch("status") }
      assert_equal posted.id, rows.last.fetch("members").sole.fetch("entry_id")
      assert_equal [ [ "attributes", "raw_transactions_payload", "spot", "BTCUSDT", 0 ] ], rows.first.fetch("archive_paths")
    end
  end

  test "a P2P order with one existing leg remains unresolved and cannot advance its timestamp" do
    with_binance_copy(history(p2p: [ p2p_row ])) do |context|
      trade(context, "binance_p2p_order-01")

      result = plan(context)

      refute result.ready?
      assert_nil result.cached_history
      row = result.document.fetch("rows").sole
      assert_equal [ "order-01", "BUY", TIMESTAMP, "unresolved" ], row.values_at("order_id", "side", "timestamp_ms", "status")
      assert_equal %w[posted cached_record_not_posted], row.fetch("members").map { |member| member.fetch("status") }
      assert_equal "binance_p2p_order-01_funding", result.document.fetch("blockers").sole.fetch("external_id")
    end
  end

  test "P2P funding alone and entirely unposted cached orders expose every missing financial leg" do
    with_binance_copy(history(p2p: [ p2p_row, p2p_row(order: "other-order") ])) do |context|
      transaction(context, "binance_p2p_order-01_funding")
      result = plan(context)
      assert_nil result.cached_history
      assert_equal %w[binance_p2p_order-01 binance_p2p_other-order binance_p2p_other-order_funding],
        result.document.fetch("blockers").map { |blocker| blocker.fetch("external_id") }
    end
  end

  test "exact duplicate occurrences keep all archive paths but conflicting repeated IDs block the seed" do
    raw = trade_row(id: 5)
    with_binance_copy(history(spot: { "BTCUSDT" => [ raw, raw.deep_dup ] })) do |context|
      trade(context, "binance_spot_BTCUSDT_5")
      result = plan(context)
      assert result.ready?
      row = result.document.fetch("rows").sole
      assert_equal [ 0, 1 ], row.fetch("archive_paths").map(&:last)
      assert_equal Digest::SHA256.hexdigest(Value.dump(raw)), row.fetch("raw_checksum")
    end
    with_binance_copy(history(spot: { "BTCUSDT" => [ raw, raw.merge("qty" => "2") ] })) do |context|
      trade(context, "binance_spot_BTCUSDT_5")
      result = plan(context)
      assert_nil result.cached_history
      assert_equal "conflicting_cached_identity", result.document.fetch("blockers").sole.fetch("code")
      assert_equal 2, result.document.fetch("rows").size
    end
  end

  test "the same P2P order cannot silently change side or timestamp in retained cache duplicates" do
    with_binance_copy(history(p2p: [ p2p_row, p2p_row(side: "SELL", time: TIMESTAMP + 1) ])) do |context|
      post_p2p(context)
      result = plan(context)
      assert_nil result.cached_history
      assert_equal [ "conflicting_cached_identity" ], result.document.fetch("blockers").map { |blocker| blocker.fetch("code") }
    end
  end

  test "legacy IDs that native parsing would rewrite remain explicit review blockers" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row(id: "001") ] })) do |context|
      original = trade(context, "binance_spot_BTCUSDT_001")
      result = plan(context)
      assert_nil result.cached_history
      assert_equal "unreviewed_cached_record", result.document.fetch("blockers").sole.fetch("code")
      assert_equal [ [ "attributes", "raw_transactions_payload", "spot", "BTCUSDT", 0 ] ], result.document.fetch("blockers").sole.fetch("archive_paths")
      assert_equal "binance_spot_BTCUSDT_001", original.reload.external_id
    end
  end

  test "unknown quotes stablecoin base pairs and another pair named in a response are blocked" do
    cache = history(spot: { "BTCXYZ" => [ trade_row ], "USDCUSDT" => [ trade_row ], "ETHUSDT" => [ trade_row.merge("symbol" => "BTCUSDT") ] })
    with_binance_copy(cache) do |context|
      result = plan(context)
      assert_nil result.cached_history
      assert_equal [ "unreviewed_cached_record" ] * 3, result.document.fetch("blockers").map { |blocker| blocker.fetch("code") }
    end
  end

  test "a source mismatch or incompatible financial type cannot satisfy a legacy duplicate skip" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row(id: 1), trade_row(id: 2) ] })) do |context|
      trade(context, "binance_spot_BTCUSDT_1", source: "manual")
      transaction(context, "binance_spot_BTCUSDT_2")
      result = plan(context)
      assert_nil result.cached_history
      assert_equal %w[conflicting_source incompatible_financial_type], result.document.fetch("blockers").map { |blocker| blocker.fetch("code") }
    end
  end

  test "one exact provider match plus a manual collision cannot be treated as a unique posting" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row ] })) do |context|
      trade(context, "binance_spot_BTCUSDT_1")
      trade(context, "binance_spot_BTCUSDT_1", source: nil)
      result = plan(context)
      assert_nil result.cached_history
      assert_equal "identity_claimed_by_multiple_entries", result.document.fetch("blockers").sole.fetch("code")
    end
  end

  test "a reused entryable cannot satisfy two otherwise distinct cached identities" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row(id: 1), trade_row(id: 2) ] })) do |context|
      first = trade(context, "binance_spot_BTCUSDT_1")
      second = trade(context, "binance_spot_BTCUSDT_2")
      original_entryable_id = second.entryable_id
      second.update_columns(entryable_id: first.entryable_id)
      result = plan(context)
      assert_nil result.cached_history
      assert_equal [ "ambiguous_or_missing_entryable" ] * 2, result.document.fetch("blockers").map { |blocker| blocker.fetch("code") }
    ensure
      second&.update_columns(entryable_id: original_entryable_id) if original_entryable_id
    end
  end

  test "exact retained copy and link context can be rechecked without changing the original copy run" do
    with_binance_copy(history) do |context|
      result = plan(context)
      binding = result.document.fetch("context")
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), binding.fetch("copy_run_id")
      assert_equal context.mapping.source_checksum, binding.fetch("archive_checksum")
      assert_equal context.mapping.id, binding.fetch("migration_mapping_id")
      assert_equal context.link.reload.lock_version, binding.fetch("account_provider_revision")
      assert_equal result.document, plan(context, expected_context: binding).document
      context.link.touch
      assert_raises(Plan::InvalidContext) { plan(context, expected_context: binding) }
      assert_equal binding.fetch("copy_run_id"), context.control.reload.high_water_mark.fetch("copy_run_id")
    end
  end

  test "changing a live source cache invalidates the retained archive instead of reusing new maxima" do
    with_binance_copy(history) do |context|
      context.source.update!(raw_transactions_payload: history(spot: { "BTCUSDT" => [ trade_row(id: 100) ] }))
      assert_raises(Plan::InvalidContext) { plan(context) }
    end
  end

  test "a same-family post-copy relink cannot turn cached rows in another financial account into history proof" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row ] })) do |context|
      replacement = context.family.accounts.create!(name: "Another Binance account", currency: "USD", balance: 0, accountable: Crypto.new)
      context.link.update!(account: replacement)
      replacement.entries.create!(external_id: "binance_spot_BTCUSDT_1", source: "binance", date: Date.current, name: "Unrelated trade", amount: 12,
        currency: "USD", entryable: Trade.new(security: securities(:aapl), qty: 1, price: 12, currency: "USD"))

      assert_raises(Plan::InvalidContext) { plan(context) }
      assert_empty context.account.entries
    ensure
      # Restore only test ownership so the shared real-commit cleanup can remove
      # the copied graph; neither planning nor its failure changes that graph.
      context.link.update_columns(account_id: context.account.id) if replacement
      replacement&.destroy!
    end
  end

  test "a nonfirst mapped account uses the exact retained cursor without consuming another accounts cache" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row ] }), nonfirst: true) do |context|
      trade(context, "binance_spot_BTCUSDT_1")
      result = plan(context)
      assert result.ready?
      assert_equal context.mapping.id, result.document.fetch("context").fetch("retained_account_binding").fetch("mapping_id")
      assert_equal 2, result.document.fetch("context").fetch("retained_copy_context").fetch("account_count")
      assert_equal [ "binance_spot_BTCUSDT_1" ], result.document.fetch("rows").map { |row| row.fetch("external_id") }
    end
  end

  test "cached future timestamps cannot push the initial P2P boundary beyond the copied observation" do
    with_binance_copy(history(p2p: [ p2p_row(time: (Time.current.to_i + 86400) * 1000) ])) do |context|
      post_p2p(context)
      result = plan(context)
      assert_nil result.cached_history
      assert_equal "unreviewed_cached_record", result.document.fetch("blockers").sole.fetch("code")
    end
  end

  test "foreign families shadow copies changed namespaces and noncombined accounts fail closed" do
    with_binance_copy(history) do |context|
      assert_raises(Plan::InvalidContext) { Plan.new(mapping: context.mapping, family: families(:empty)).call }
      context.control.update!(state: "shadow")
      assert_raises(Plan::InvalidContext) { plan(context) }
      context.control.update!(state: "quiescing")
      context.mapping.external_account.update_columns(identity_namespace: "other")
      assert_raises(Plan::InvalidContext) { plan(context) }
    end
    with_binance_copy(history, account_type: "spot") do |context|
      assert_raises(Plan::InvalidContext) { plan(context) }
    end
  end

  test "a malformed cache or a record bound overflow cannot produce a truncated seed" do
    with_binance_copy({ "spot" => [ trade_row ] }) do |context|
      assert_raises(Plan::InvalidContext) { plan(context) }
    end
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row, trade_row(id: 2) ] })) do |context|
      with_constant(:MAX_RECORDS, 1) { assert_raises(Plan::InvalidContext) { plan(context) } }
    end
  end

  test "encrypted state preflight stops before archive decoding" do
    with_binance_copy(history) do |context|
      Provider::AccountData::MigrationCopier.any_instance.expects(:snapshot_for).never
      with_constant(:MAX_STATE_BYTES, 1) { assert_raises(Plan::InvalidContext) { plan(context) } }
    end
  end

  test "the cache archive read has a decoded byte bound" do
    with_binance_copy(history) do |context|
      with_constant(:MAX_ARCHIVE_BYTES, 1) { assert_raises(Plan::InvalidContext) { plan(context) } }
    end
  end

  test "candidate history retains sold-out pairs and inclusive P2P boundary in the existing native constructor seam" do
    with_binance_copy(history(spot: { "BTCUSDT" => [ trade_row(id: 42) ] }, p2p: [ p2p_row ])) do |context|
      trade(context, "binance_spot_BTCUSDT_42")
      post_p2p(context)
      result = plan(context)
      client = mock("Binance history requests")
      observed_at = Time.at((TIMESTAMP + 10_000) / 1000).utc
      adapter = Provider::AccountData::Binance.new(client: client, currency: "USD", timezone: "UTC", observed_at: observed_at,
        cached_history: result.cached_history)
      external = Ingestion::Record.account(external_id: "combined", name: "Binance", currency: "USD", metadata: { portfolio_sources: {} })
      %w[BUY SELL].each do |side|
        client.expects(:get_p2p_page).with(trade_type: side, start_time: TIMESTAMP, end_time: observed_at.to_i * 1000, page: 1)
          .returns(items: [], next_cursor: nil)
      end
      first = adapter.fetch_activities(account: external)
      second = adapter.fetch_activities(account: external, cursor: first.next_cursor)
      client.expects(:get_trades_page).with("BTCUSDT", market: "spot", from_id: 43).returns(items: [], next_cursor: nil)
      refute adapter.fetch_activities(account: external, cursor: second.next_cursor).complete?
      refute_includes result.inspect, "order-01"
      refute_includes result.inspect, context.mapping.source_checksum
    end
  end

  private
    def with_binance_copy(cache, account_type: "combined", nonfirst: false)
      with_provider_encryption do
        family = families(:dylan_family)
        item = BinanceItem.create!(family: family, name: "Retained Binance", api_key: "private-plan-key", api_secret: "private-plan-secret")
        account = family.accounts.create!(name: "Existing Binance", currency: "USD", balance: 1000, accountable: Crypto.new)
        begin
          attributes = { name: "Binance source", account_type: account_type, currency: "USD", current_balance: 1000,
            raw_payload: { "assets" => [] }, raw_transactions_payload: cache }
          if nonfirst
            item.binance_accounts.create!(id: "00000000-0000-4000-8000-000000000001", name: "Older source", account_type: "spot", currency: "USD")
            attributes[:id] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
          end
          source = item.binance_accounts.create!(attributes)
          link = AccountProvider.create!(account: account, provider: source)
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "binance", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: source.id)
          yield Copied.new(family: family, item: item, source: source, account: account, link: link.reload, copier: copier, control: control, mapping: mapping)
        ensure
          cleanup_identity_source(item, account)
        end
      end
    end

    def plan(context, **options)
      Plan.new(mapping: context.mapping, family: context.family).call(**options)
    end

    def history(spot: {}, futures: {}, p2p: [])
      { "spot" => spot, "futures" => futures, "p2p" => p2p, "fetched_at" => "2023-11-15T00:00:00Z" }
    end

    def trade_row(id: 1)
      { "id" => id, "time" => TIMESTAMP, "qty" => "0.1", "price" => "35000", "quoteQty" => "3500", "commission" => "0", "isBuyer" => true }
    end

    def p2p_row(order: "order-01", side: "BUY", time: TIMESTAMP)
      { "orderNumber" => order, "tradeType" => side, "createTime" => time, "fiat" => "USD", "totalPrice" => "10",
        "unitPrice" => "1", "amount" => "10", "takerAmount" => "9.9", "takerCommission" => "0.1", "asset" => "USDT" }
    end

    def trade(context, id, source: "binance")
      context.account.entries.create!(external_id: id, source: source, date: Date.current, name: "Original Binance trade", amount: 12,
        currency: "USD", entryable: Trade.new(security: securities(:aapl), qty: 1, price: 12, currency: "USD"))
    end

    def transaction(context, id)
      context.account.entries.create!(external_id: id, source: "binance", date: Date.current, name: "Original P2P funding", amount: 12,
        currency: "USD", entryable: Transaction.new)
    end

    def post_p2p(context, order: "order-01")
      [ trade(context, "binance_p2p_#{order}"), transaction(context, "binance_p2p_#{order}_funding") ]
    end

    def with_constant(name, value)
      original = Plan.const_get(name)
      Plan.send(:remove_const, name)
      Plan.const_set(name, value)
      yield
    ensure
      Plan.send(:remove_const, name)
      Plan.const_set(name, original)
    end
end
