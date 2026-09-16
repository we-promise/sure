require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::TradeRepublic::RetainedPortfolioTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Collector = Provider::AccountData::TradeRepublic::RetainedPortfolio

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Registry.stubs(:fetch).with("trade_republic").returns(Provider::AccountData::TradeRepublic)
    @family_id = families(:dylan_family).id
    @family_timestamps = Family.find(@family_id).attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
  end

  teardown do
    Family.where(id: @family_id).update_all(@family_timestamps)
    travel_back
  end

  test "verified kinds preserve copied source and financial UUIDs through the real factory and inventory" do
    with_source do |context|
      before = context.fetch(:accounts).transform_values { |account| account.reload.attributes }
      original_ids = context.fetch(:externals).transform_values(&:id)
      client = mock("restored session discovery")
      client.expects(:get_account).returns(owner)
      adapter = build_adapter(context, client)
      page, proof = adapter.request_grant.capture_request { adapter.list_accounts }

      assert_equal %w[portfolio cash], page.records.map { |row| row[:external_id] }
      assert_equal %w[Investment Depository], page.records.map { |row| row[:account_type] }
      assert_equal original_ids, context.fetch(:connection).external_accounts.index_by(&:external_id).transform_values(&:id)
      assert_equal before, context.fetch(:accounts).transform_values { |account| account.reload.attributes }
      assert_equal context.fetch(:links).transform_values(&:id), context.fetch(:externals).transform_values { |external| external.reload.account_provider.id }
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: context.fetch(:connection), capture: proof, require_runtime_inputs: true)
      assert context.fetch(:connection).disabled?
      refute Provider::AccountData::TradeRepublic.native_ready?

      input = capture(context)
      portfolio = input.fetch("accounts").fetch(original_ids.fetch("portfolio"))
      assert input.frozen?
      assert portfolio.fetch("positions").frozen?
      assert_equal "DE123", portfolio.fetch("remote_id")
      assert_equal context.fetch(:control).high_water_mark.fetch("copy_run_id"), portfolio.dig("context", "source", "copy_run_id")
      assert_equal context.fetch(:mappings).fetch("portfolio").source_checksum, portfolio.dig("context", "source", "source_checksum")
    end
  end

  test "old prices have exact archive provenance but cannot supply current quantities completeness or a new total" do
    with_source do |context|
      client = mock("current positions without current quotes")
      client.expects(:get_portfolio).twice.returns(account: owner,
        portfolio: { categories: [ { categoryType: "stocksAndETFs", positions: [ { instrumentId: "US0378331005", netSize: "2.5", averageBuyIn: "90.25" } ] } ] })
      client.expects(:get_price).twice.returns(account: owner, price: nil, attempts: [])
      adapter = build_adapter(context, client)
      portfolio = adapter.normalize_account(owner, kind: "portfolio")
      page, = adapter.request_grant.capture_request { adapter.fetch_holdings(account: portfolio) }
      holding = page.records.sole
      assert_equal "trade_republic_position_DE123_US0378331005_2026-09-15", holding[:external_id]
      assert_equal BigDecimal("100.125"), holding[:price]
      assert_equal BigDecimal("2.5"), holding[:quantity]
      assert_equal BigDecimal("250.3125"), holding[:amount]
      assert_equal BigDecimal("90.25"), holding[:metadata][:cost_basis]
      refute page.complete?
      refute page.coverage["absence_authoritative"]
      assert_equal BigDecimal("100.125"), page.evidence.dig("cached_prices", "US0378331005")
      assert_equal 5.days.ago.iso8601(9), page.evidence.dig("cached_price_source", "last_positions_sync")
      assert_equal context.fetch(:mappings).fetch("portfolio").source_checksum, page.evidence.dig("cached_price_source", "source", "source_checksum")
      known = Ingestion::Record.account(**portfolio.attributes.merge(balance: BigDecimal("700")))
      balance, = adapter.request_grant.capture_request { adapter.fetch_balance(account: known) }
      assert_equal BigDecimal("700"), balance.records.sole[:balance]
      assert_empty context.fetch(:accounts).fetch("portfolio").holdings
    end
  end

  test "both timeline topics route to the exact retained local identities through captured factory inputs" do
    with_source do |context|
      client = mock("two topics one exact owner")
      client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ event ]))
      client.expects(:get_event_detail).with(event_id: "cash-event").returns(account: owner, response: {})
      client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([]))
      adapter = build_adapter(context, client)
      bindings = context.fetch(:externals).to_h do |kind, external|
        [ kind, { "resource" => "activities", "account_id" => external.current_account.id, "account_currency" => "EUR" } ]
      end
      groups = []
      generation_id = SecureRandom.uuid
      3.times do
        group, = adapter.request_grant.capture_request do
          adapter.fetch_activity_group(start_cursor: nil, generation_id: generation_id, cursor: groups.last&.next_cursor,
            captured_groups: groups, accounts: bindings)
        end
        groups << group
      end
      assert groups.last.complete?
      pages = Ingestion::TransactionGroupAssembler.new.assemble(groups)
      assert_equal %w[cash portfolio], pages.keys.sort
      assert_empty pages.fetch("portfolio").records
      assert_equal [ "trade_republic_event_cash-event" ], pages.fetch("cash").records.map { |record| record[:external_id] }
      assert_equal context.fetch(:externals).fetch("cash").id,
        groups.first.evidence.dig("trade_republic_timeline", "context", "topology", "cash", "external_account_id")
      assert_empty context.fetch(:connection).provider_sync_checkpoints.where(stream: "activities")
      assert context.fetch(:accounts).values.all? { |account| account.entries.empty? }
    end
  end

  test "missing sibling is a new canonical source and an unlinked retained cash account does not redirect portfolio history" do
    with_source(kinds: [ "portfolio" ]) do |context|
      client = mock("missing cash discovery")
      client.expects(:get_account).returns(owner)
      adapter = build_adapter(context, client)
      page, = adapter.request_grant.capture_request { adapter.list_accounts }
      assert_equal [ "portfolio", "cash:DE123" ], page.records.map { |record| record[:external_id] }
      cash = create_external_account(context.fetch(:connection), external_id: "cash:DE123", currency: "EUR")
      assert adapter.request_grant.verify!, "New unlinked discovery must not invent or invalidate a retained alias"
      assert_nil cash.account_provider
    end
    with_source(unlinked: [ "cash" ]) do |context|
      adapter = build_adapter(context, mock("no network for pure routing"))
      account = adapter.normalize_account(owner, kind: "portfolio")
      retained = adapter.normalize_legacy_activity({ id: "prior-cash", category: "PAYMENT_RECEIVED", timestamp: Time.current.iso8601,
        detail: { amount: "10", currency: "EUR" } }, account: account)
      assert_equal "trade_republic_event_prior-cash", retained[:external_id]
      assert_nil context.fetch(:externals).fetch("cash").account_provider
    end
  end

  test "missing remote IDs noncanonical cash and incompatible owners require explicit reconciliation before requests" do
    [ { "portfolio" => nil }, { "cash" => "NOT-PREFIXED" }, { "cash" => "cash:OTHER" } ].each do |remote_ids|
      with_source(remote_ids: remote_ids) do |context|
        client = mock("no request for unresolved topology")
        client.expects(:get_account).never
        assert_raises(Provider::AccountData::StaleWriter) { build_adapter(context, client) }
      end
    end
    with_source do |context|
      client = mock("wrong restored session")
      client.expects(:get_account).returns(owner.merge(securitiesAccountNumber: "OTHER"))
      adapter = build_adapter(context, client)
      assert_raises(Provider::AccountData::InvalidResponse) { adapter.request_grant.capture_request { adapter.list_accounts } }
      assert_equal %w[cash portfolio], context.fetch(:connection).external_accounts.pluck(:external_id).sort
    end
  end

  test "duplicate cached instruments and a second unmapped portfolio cannot silently overwrite retained identity" do
    with_source(positions: [ { "isin" => "US0378331005", "price" => "1" }, { "isin" => "US0378331005", "price" => "2" } ]) do |context|
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
    with_source do |context|
      create_external_account(context.fetch(:connection), external_id: "DE123", currency: "EUR")
      assert_raises(Provider::AccountData::StaleWriter) { build_adapter(context, mock("ambiguous portfolio")) }
    end
  end

  test "a missing archive or mapping never falls back to alias guessing" do
    with_source do |context|
      external = context.fetch(:externals).fetch("portfolio")
      archive = context.fetch(:connection).ingestion_batches.find_by!(stream: "legacy_snapshot", external_account: external, sequence: 0)
      ProviderMigrationAccountBinding.where(first_batch_id: archive.id).delete_all
      archive.delete
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
      context.fetch(:mappings).fetch("portfolio").delete
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
  end

  test "post-copy relinking foreign inventory and namespace substitution fail original binding admission" do
    with_source do |context|
      ApplicationRecord.transaction do
        context.fetch(:links).fetch("portfolio").update!(account: accounts(:investment))
        assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
        raise ActiveRecord::Rollback
      end
      ApplicationRecord.transaction do
        context.fetch(:externals).fetch("portfolio").update_columns(identity_namespace: "foreign")
        assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
        raise ActiveRecord::Rollback
      end
      foreign = create_provider_connection(provider_key: "trade_republic", family: families(:empty), credentials: { "session_blob" => "foreign" })
      begin
        external = create_external_account(foreign)
        context.fetch(:connection).with_lock do
          assert_raises(Provider::AccountData::StaleWriter) do
            Collector.build(connection: context.fetch(:connection), observed_at: Time.current, external_accounts: [ external ])
          end
        end
      ensure
        foreign.destroy!
      end
    end
  end

  test "replay checks descriptors without reading archives and rejects changed source context before the next request" do
    with_source do |context|
      client = mock("only original discovery")
      client.expects(:get_account).once.returns(owner)
      adapter = build_adapter(context, client)
      Provider::AccountData::MigrationCopier.any_instance.expects(:snapshot_for).never
      _page, proof = adapter.request_grant.capture_request { adapter.list_accounts }
      ProviderSyncCheckpoint.create!(provider_connection: context.fetch(:connection), stream: "activities", scope_key: "connection", cursor: "native-progress")
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: context.fetch(:connection), capture: proof, require_runtime_inputs: true)
      mapping = context.fetch(:mappings).fetch("portfolio")
      mapping.update!(source_checksum: "v1-#{'f' * 64}")
      assert_raises(Provider::AccountData::StaleWriter) { adapter.request_grant.capture_request { adapter.list_accounts } }
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: context.fetch(:connection), capture: proof, require_runtime_inputs: true)
      end
    end
  end

  test "native portfolio unlink preserves aliases and sibling requests but omits its cached financial prices" do
    with_source do |context|
      context.fetch(:control).update!(state: "active") # Fixture admission, not a cutover command.
      portfolio = context.fetch(:accounts).fetch("portfolio")
      Account::SourcePolicy.select!(account: portfolio, account_provider: context.fetch(:links).fetch("portfolio"), resource: "holdings")
      client = mock("Trade Republic detached portfolio")
      client.expects(:get_account).twice.returns(owner)
      original = build_adapter(context, client)
      _page, proof = original.request_grant.capture_request { original.list_accounts }
      archives = context.fetch(:connection).ingestion_batches.order(:id).map(&:attributes)

      assert Account::Unlink.new(account: portfolio, user: users(:family_admin)).call

      assert_raises(Provider::AccountData::StaleWriter) { original.request_grant.capture_request { flunk "Detached portfolio reached HTTP" } }
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: context.fetch(:connection), capture: proof, require_runtime_inputs: true)
      end
      fresh = build_adapter(context, client)
      page, = fresh.request_grant.capture_request { fresh.list_accounts }
      assert_equal %w[portfolio cash], page.records.map { |record| record[:external_id] }
      snapshot = capture(context).fetch("accounts").fetch(context.fetch(:externals).fetch("portfolio").id)
      assert_equal "DE123", snapshot.fetch("remote_id")
      assert_empty snapshot.fetch("positions")
      assert_nil snapshot.fetch("last_positions_sync")
      assert_equal context.fetch(:links).fetch("cash").id, context.fetch(:externals).fetch("cash").reload.account_provider.id
      cash = fresh.normalize_account(owner, kind: "cash")
      client.expects(:get_cash).returns(account: owner, cash: { amount: "700", currency: "EUR" })
      # The linked sibling still has its original captured input and source ID.
      assert_equal "cash", cash[:external_id]
      balance, = fresh.request_grant.capture_request { fresh.fetch_balance(account: cash) }
      assert_equal BigDecimal("700"), balance.records.sole[:balance]
      assert_equal archives, context.fetch(:connection).ingestion_batches.order(:id).map(&:attributes)
      assert_equal BigDecimal("700"), portfolio.reload.balance

      source = context.fetch(:item).trade_republic_accounts.find_by!(kind: "portfolio")
      AccountProvider.create!(account: portfolio, provider: source, external_account: context.fetch(:externals).fetch("portfolio").reload)
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
  end

  test "detached portfolio still requires a valid original remote identity" do
    with_source(remote_ids: { "portfolio" => nil }) do |context|
      context.fetch(:control).update!(state: "active")
      assert Account::Unlink.new(account: context.fetch(:accounts).fetch("portfolio"), user: users(:family_admin)).call
      assert_raises(Provider::AccountData::StaleWriter) { capture(context) }
    end
  end

  private
    def with_source(kinds: %w[portfolio cash], remote_ids: {}, unlinked: [], positions: nil)
      with_provider_encryption do
        family = Family.find(@family_id)
        item = TradeRepublicItem.create!(family: family, name: "Retained portfolio", currency: "EUR", session_blob: "retained-session")
        financials, links = {}, {}
        control = nil
        begin
          kinds.each do |kind|
            remote = remote_ids.fetch(kind) { kind == "cash" ? "cash:DE123" : "DE123" }
            source = item.trade_republic_accounts.create!(kind: kind, trade_republic_account_id: remote, name: kind.capitalize, currency: "EUR",
              current_balance: 700, cash_balance: kind == "cash" ? 700 : 0, last_positions_sync: 5.days.ago, holdings_snapshot_complete: true,
              raw_positions_payload: kind == "cash" ? [] : (positions || [ { "isin" => "US0378331005", "price" => 100.125, "quantity" => "999" } ]))
            next if unlinked.include?(kind)
            financials[kind] = family.accounts.create!(name: "Retained #{kind}", currency: "EUR", balance: 700,
              accountable: kind == "cash" ? Depository.new : Investment.new)
            links[kind] = AccountProvider.create!(account: financials.fetch(kind), provider: source)
          end
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "trade_republic", legacy_item_id: item.id)
          10.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          connection = control.provider_connection
          externals = connection.external_accounts.index_by(&:external_id)
          mappings = externals.transform_values { |external| control.provider_migration_mappings.find_by!(role: "external_account", external_account: external) }
          yield({ item: item, accounts: financials, links: links.transform_values(&:reload), control: control,
            connection: connection, externals: externals, mappings: mappings })
        ensure
          connection = control&.provider_connection
          connection&.provider_sync_checkpoints&.delete_all
          ProviderMigrationAccountBinding.where(family_id: control.family_id,
            provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
          connection&.ingestion_batches&.delete_all
          connection&.syncs&.delete_all
          Account::SourcePolicy.where(account_id: financials.values.map(&:id)).delete_all
          AccountProvider.where(account_id: financials.values.map(&:id)).delete_all
          control&.provider_migration_mappings&.delete_all
          control&.delete
          connection&.destroy!
          financials.each_value { |account| account.reload.destroy! }
          item.trade_republic_accounts.delete_all
          item.delete
        end
      end
    end

    def build_adapter(context, client)
      Provider::TradeRepublicClient::IngestionClient.stubs(:new).returns(client)
      Provider::AccountData::Registry.build(context.fetch(:connection), observed_at: Time.current)
    end

    def capture(context)
      connection = context.fetch(:connection)
      connection.with_lock { Collector.build(connection: connection, observed_at: Time.current) }
    end

    def owner
      { securitiesAccountNumber: "DE123", currency: "EUR" }
    end

    def event
      { id: "cash-event", timestamp: "2026-09-12T12:00:00Z", eventType: "INCOMING_TRANSFER", title: "Transfer", amount: { value: "10", currency: "EUR" } }
    end

    def response(rows)
      { account: owner, response: { items: rows }, next_cursor: nil }
    end
end
