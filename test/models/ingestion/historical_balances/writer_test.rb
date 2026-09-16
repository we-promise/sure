require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Ingestion::HistoricalBalances::WriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "applies captured equity totals while preserving cash financial UUIDs and existing creation timestamps" do
    with_scenario do
      first = seed_balance("2026-05-07", total: "900", cash: "400")
      second = seed_balance("2026-05-08", total: "1000", cash: "300")
      entry = trade(amount: "100", source: "manual", user_modified: true)
      batch = plan.capture!(phase: "equity_history")
      command = Ingestion::HistoricalBalances::Command.load(batch.payload)
      assert_equal 2, command[:rows].size
      assert_equal BigDecimal("100"), command[:rows].last[:non_cash_adjustments]
      assert_equal BigDecimal("200"), command[:rows].last[:net_market_flows]
      identifiers = [ first.id, second.id, entry.id, entry.entryable_id ]
      created_at = [ first.created_at, second.created_at ]
      assert_no_difference [ "Balance.count", "Entry.count", "Trade.count" ] do
        result = apply(batch)
        assert_equal 2, result[:applied_rows]
      end
      assert batch.reload.applied?
      assert_equal BigDecimal("1000"), first.reload.end_balance
      assert_equal BigDecimal("1200"), second.reload.end_balance
      assert_equal BigDecimal("300"), second.cash_balance
      assert_equal identifiers, [ first.id, second.id, entry.reload.id, entry.entryable_id ]
      assert_equal created_at, [ first.created_at, second.created_at ]
      assert entry.user_modified?
      assert_provider_column_encrypted(batch, :payload, "inputs_sha256")
    end
  end

  test "replay does not apply the same command again or need current market rates" do
    with_scenario do
      seed_balance("2026-05-07", total: "900", cash: "400")
      seed_balance("2026-05-08", total: "1000", cash: "300")
      rate = mock("one dated rate")
      rate.expects(:call).once.with(from: "EUR", to: "USD", date: Date.new(2026, 5, 8)).returns(rate: BigDecimal("1.25"), date: "2026-05-07")
      trade(amount: "80", currency: "EUR")
      batch = plan(rate_resolver: rate).capture!(phase: "equity_history")
      assert_equal batch.id, plan(rate_resolver: rate).capture!(phase: "equity_history").id
      assert_equal BigDecimal("100"), Ingestion::HistoricalBalances::Command.load(batch.payload)[:rows].last[:non_cash_adjustments]
      apply(batch)
      before = @account.balances.order(:id).map(&:attributes)
      assert apply(batch)[:replay]
      assert_equal before, @account.balances.order(:id).map(&:attributes)
    end
  end

  test "all-account trades include other providers manual and protected trades but exclude zero quantity" do
    with_scenario do
      trade(amount: "10", source: "manual", user_modified: true)
      trade(amount: "20", source: "different_provider", excluded: true)
      trade(amount: "999", quantity: "0")
      command = plan.prepare(phase: "equity_history")
      assert_equal BigDecimal("30"), command[:rows].last[:non_cash_adjustments]
      assert_equal 2, command[:fx_evidence].size
      assert_equal [ "same_currency" ], command[:fx_evidence].map { |row| row["origin"] }.uniq
    end
  end

  test "a later account sync may capture newly available FX against the same source snapshot" do
    with_scenario do
      seed_balance("2026-05-08", total: "777", cash: "300")
      trade(amount: "80", currency: "EUR")
      unavailable = mock("earlier missing rate")
      unavailable.expects(:call).once.returns(nil)
      first = plan(rate_resolver: unavailable, capture_revision: "first-account-sync").capture!(phase: "equity_history")
      available = mock("later available rate")
      available.expects(:call).once.returns(rate: BigDecimal("1.25"), date: "2026-05-08")
      second = plan(rate_resolver: available, capture_revision: "second-account-sync").capture!(phase: "equity_history")
      assert_not_equal first.id, second.id
      assert_not first.complete?
      assert second.complete?
      assert_equal BigDecimal("100"), Ingestion::HistoricalBalances::Command.load(second.payload)[:rows].last[:non_cash_adjustments]
    end
  end

  test "stored trade FX takes precedence and captures the legacy persisted rate without network" do
    with_scenario do
      entry = trade(amount: "80", currency: "EUR")
      entry.trade.update!(exchange_rate: 1.25)
      rate = mock("market rates are unnecessary")
      rate.expects(:call).never
      command = plan(rate_resolver: rate).prepare(phase: "equity_history")
      assert_equal BigDecimal("100"), command[:rows].last[:non_cash_adjustments]
      assert_equal "stored_trade", command[:fx_evidence].sole["origin"]
      assert_equal BigDecimal("1.25"), command[:fx_evidence].sole["rate"]
    end
  end

  test "missing FX excludes the whole date and preserves its previously materialized balance" do
    with_scenario do
      retained = seed_balance("2026-05-08", total: "777", cash: "300")
      before = retained.attributes
      trade(amount: "80", currency: "EUR")
      rate = mock("missing rate")
      rate.expects(:call).once.returns(nil)
      batch = plan(rate_resolver: rate).capture!(phase: "equity_history")
      assert_not batch.complete?
      DebugLogEntry.expects(:capture).once.with do |attributes|
        attributes[:metadata][:ingestion_batch_id] == batch.id && attributes[:metadata][:failed_fx_dates] == [ "2026-05-08" ]
      end
      result = apply(batch)
      assert_equal [ Date.new(2026, 5, 8) ], result[:failed_fx_dates]
      assert_equal before, retained.reload.attributes
      assert batch.reload.applied?
    end
  end

  test "a failed middle day stays unchanged and the next published day starts from its retained value" do
    with_scenario(equity_rows: [ { "report_date" => "2026-05-06", "total" => "1000" },
      { "report_date" => "2026-05-07", "total" => "1100" }, { "report_date" => "2026-05-08", "total" => "1200" } ]) do
      seed_balance("2026-05-06", total: "900", cash: "400")
      retained = seed_balance("2026-05-07", total: "777", cash: "200")
      following = seed_balance("2026-05-08", total: "1100", cash: "300")
      entry = trade(amount: "80", currency: "EUR", date: Date.new(2026, 5, 7))
      preserved = retained.reload.attributes
      entry_before = entry.reload.attributes
      rate = mock("middle day has no FX")
      rate.expects(:call).once.with(from: "EUR", to: "USD", date: Date.new(2026, 5, 7)).returns(nil)
      batch = plan(rate_resolver: rate).capture!(phase: "equity_history")
      assert_equal 2, apply(batch)[:applied_rows]
      assert_equal preserved, retained.reload.attributes
      assert_equal entry_before, entry.reload.attributes
      assert_equal retained.end_balance, following.reload.start_balance
      assert_equal BigDecimal("577"), following.start_non_cash_balance
      assert_equal BigDecimal("323"), following.net_market_flows
      assert_equal BigDecimal("1200"), following.end_balance
      published = following.attributes
      assert apply(batch)[:replay]
      assert_equal published, following.reload.attributes
    end
  end

  test "an unmaterialized failed FX date blocks capture without changing financial records" do
    with_scenario do
      trade(amount: "80", currency: "EUR")
      rate = mock("missing rate and materialization")
      rate.expects(:call).once.returns(nil)
      assert_no_difference [ "IngestionBatch.count", "Balance.count", "Entry.count" ] do
        assert_raises(Provider::AccountData::IncompletePage) { plan(rate_resolver: rate).capture!(phase: "equity_history") }
      end
    end
  end

  test "financial input changes after FX capture reject application atomically" do
    with_scenario do
      seed_balance("2026-05-07", total: "900", cash: "400")
      trade(amount: "100")
      batch = plan.capture!(phase: "equity_history")
      before = @account.balances.map(&:attributes)
      trade(amount: "5", source: "new_manual_trade")
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_equal before, @account.balances.map(&:attributes)
      assert batch.reload.captured?
    end
  end

  test "changed materialized cash is detected even when the provider snapshot is unchanged" do
    with_scenario do
      row = seed_balance("2026-05-08", total: "900", cash: "400")
      batch = plan.capture!(phase: "equity_history")
      row.update!(cash_balance: "123")
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_equal BigDecimal("123"), row.reload.cash_balance
      assert_equal BigDecimal("900"), row.balance
    end
  end

  test "a later writer epoch or revoked source selection cannot publish an old command" do
    with_scenario do
      batch = plan.capture!(phase: "equity_history")
      @connection.update!(writer_epoch: @connection.writer_epoch + 1)
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      @connection.update!(writer_epoch: batch.writer_epoch)
      @policy.update!(active: false)
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_empty @account.balances
    end
  end

  test "disabled and disconnecting connections cannot publish captured history" do
    with_scenario do
      batch = plan.capture!(phase: "equity_history")
      @connection.update!(status: "disabled")
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      @connection.update!(status: "good", scheduled_for_deletion: true)
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_empty @account.balances
    end
  end

  test "source evidence that has not completed application cannot publish a captured command" do
    with_scenario do
      batch = plan.capture!(phase: "equity_history")
      @source.update!(status: "applying")
      assert_raises(Provider::AccountData::InvalidResponse) { plan.prepare(phase: "equity_history") }
      assert_raises(Provider::AccountData::InvalidResponse) { apply(batch) }
      assert_empty @account.balances
    end
  end

  test "retired compatibility rows retain native historical authority and a pause revokes it" do
    with_scenario do
      control = ProviderMigrationControl.create!(family: @account.family, provider_connection: @connection,
        provider_key: "ibkr", legacy_type: "IbkrItem", legacy_id: SecureRandom.uuid, state: "retired")
      batch = plan.capture!(phase: "equity_history")
      assert_equal 2, apply(batch)[:applied_rows]
      control.update!(state: "rollback_pending")
      assert_raises(Provider::AccountData::StaleWriter) { plan.prepare(phase: "equity_history") }
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
    end
  end

  test "changed link revision cannot publish an earlier historical command" do
    with_scenario do
      batch = plan.capture!(phase: "equity_history")
      @link.touch
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      replacement = plan.capture!(phase: "equity_history")
      assert_not_equal batch.id, replacement.id
      assert_equal @link.reload.lock_version, Ingestion::HistoricalBalances::Command.load(replacement.payload)[:account_provider_revision]
      assert_empty @account.balances
    end
  end

  test "default opening anchor repair preserves entry identity and must precede materialization" do
    with_scenario do
      anchor = valuation(date: "2026-05-01", amount: "1200", kind: "opening_anchor")
      trade(amount: "100")
      assert_raises(Provider::AccountData::InvalidResponse) { plan.prepare(phase: "equity_history") }
      batch = plan.capture!(phase: "opening_anchor")
      original_ids = [ anchor.id, anchor.entryable_id ]
      assert_no_difference [ "Entry.count", "Valuation.count" ] do
        assert apply(batch)[:anchor_repaired]
      end
      assert_equal BigDecimal("0"), anchor.reload.amount
      assert_equal original_ids, [ anchor.id, anchor.entryable_id ]
      assert_empty @account.balances
      # The caller materializes here, then captures the different post phase.
      assert_equal "equity_history", plan.prepare(phase: "equity_history")[:phase]
    end
  end

  test "protected locked and deliberately different opening anchors are preserved" do
    with_scenario do
      anchor = valuation(date: "2026-05-01", amount: "1200", kind: "opening_anchor", user_modified: true)
      trade(amount: "100")
      assert_nil plan.prepare(phase: "opening_anchor")[:opening_anchor]
      anchor.update!(user_modified: false, locked_attributes: { "amount" => true })
      assert_nil plan.prepare(phase: "opening_anchor")[:opening_anchor]
      anchor.update!(locked_attributes: {}, amount: "1199")
      assert_nil plan.prepare(phase: "opening_anchor")[:opening_anchor]
      assert_equal BigDecimal("1199"), anchor.reload.amount
    end
  end

  test "new protection on an opening anchor prevents a queued repair" do
    with_scenario do
      anchor = valuation(date: "2026-05-01", amount: "1200", kind: "opening_anchor")
      trade(amount: "100")
      batch = plan.capture!(phase: "opening_anchor")
      anchor.update!(import_locked: true)
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_equal BigDecimal("1200"), anchor.reload.amount
    end
  end

  test "historical authority alone cannot repair a current-balance owner's opening anchor" do
    with_scenario do
      anchor = valuation(date: "2026-05-01", amount: "1200", kind: "opening_anchor")
      trade(amount: "100")
      batch = plan.capture!(phase: "opening_anchor")
      @balance_policy.update!(active: false)
      assert_raises(Provider::AccountData::StaleWriter) { apply(batch) }
      assert_nil plan.prepare(phase: "opening_anchor")[:opening_anchor]
      assert_equal BigDecimal("1200"), anchor.reload.amount
    end
  end

  test "selecting balance authority does not reuse an earlier no-op anchor command" do
    with_scenario do
      valuation(date: "2026-05-01", amount: "1200", kind: "opening_anchor")
      trade(amount: "100")
      @balance_policy.update!(active: false)
      earlier = plan.capture!(phase: "opening_anchor")
      assert_nil Ingestion::HistoricalBalances::Command.load(earlier.payload)[:opening_anchor]
      Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "balances")
      replacement = plan.capture!(phase: "opening_anchor")
      assert_not_equal earlier.id, replacement.id
      assert Ingestion::HistoricalBalances::Command.load(replacement.payload)[:opening_anchor]
    end
  end

  test "protected valuation dates retain financial value and next day starts from that retained value" do
    with_scenario do
      valuation(date: "2026-05-07", amount: "1500", kind: "reconciliation", user_modified: true)
      retained = seed_balance("2026-05-07", total: "1500", cash: "400")
      seed_balance("2026-05-08", total: "1000", cash: "300")
      before = retained.attributes
      batch = plan.capture!(phase: "equity_history")
      command = Ingestion::HistoricalBalances::Command.load(batch.payload)
      assert_equal 1, command[:rows].size
      assert_equal BigDecimal("1100"), command[:rows].sole[:start_non_cash_balance]
      assert_equal BigDecimal("-200"), command[:rows].sole[:net_market_flows]
      apply(batch)
      assert_equal before, retained.reload.attributes
    end
  end

  test "capture inside a financial transaction refuses market-data collection" do
    with_scenario do
      resolver = mock("must not query FX under a transaction")
      resolver.expects(:call).never
      trade(amount: "100", currency: "EUR")
      ApplicationRecord.transaction do
        assert_raises(Provider::AccountData::InvalidResponse) { plan(rate_resolver: resolver).prepare(phase: "equity_history") }
      end
    end
  end

  test "commands round trip exact values and reject changed input snapshots or protected rows" do
    with_scenario do
      trade(amount: "100")
      command = plan.prepare(phase: "equity_history")
      restored = Ingestion::HistoricalBalances::Command.load(JSON.parse(JSON.generate(command.payload)))
      assert_equal command.data, restored.data
      altered = command.data.deep_dup
      altered["inputs"]["account"]["currency"] = "EUR"
      assert_raises(ArgumentError) { Ingestion::HistoricalBalances::Command.new(altered) }
      altered = command.data.deep_dup
      altered["protected_dates"] = [ altered["rows"].first[:date] ]
      assert_raises(ArgumentError) { Ingestion::HistoricalBalances::Command.new(altered) }
    end
  end

  private
    def with_scenario(equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000" }, { "report_date" => "2026-05-08", "total" => "1200" } ])
      with_provider_encryption do
        DebugLogEntry.stubs(:capture)
        @account = families(:empty).accounts.create!(name: "Historical command test", balance: "1000", cash_balance: "400", currency: "USD", accountable: Investment.new)
        @connection = create_provider_connection(family: @account.family, provider_key: "ibkr", writer_epoch: 1)
        @external = create_external_account(@connection, external_id: "U123", currency: "USD")
        @link = AccountProvider.create!(account: @account, external_account: @external)
        @policy = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "historical_balances")
        @balance_policy = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "balances")
        snapshot = Provider::AccountData::Ibkr::EquitySnapshot.new(external_id: "U123", currency: "USD", statement_sha256: "a" * 64,
          observed_on: Date.new(2026, 5, 8), imported_current_balance: BigDecimal("1200"),
          equity_rows: equity_rows)
        @source = create_provider_batch(@connection, external_account: @external, stream: "equity_snapshots", scope_key: "account:#{@external.id}",
          source_policy_version: @policy.id, payload: snapshot.payload)
        yield
      ensure
        @connection&.ingestion_batches&.destroy_all
        Account::SourcePolicy.where(account_id: @account.id).delete_all if @account
        @account&.account_providers&.destroy_all
        ProviderMigrationControl.where(provider_connection_id: @connection.id).destroy_all if @connection
        @connection&.reload&.destroy!
        @account&.reload&.destroy!
      end
    end

    def plan(**options)
      Ingestion::HistoricalBalances::IbkrPlan.new(external_account: @external, source_batch: @source, **options)
    end

    def apply(batch)
      Ingestion::HistoricalBalances::Writer.new(batch: batch).apply!
    end

    def seed_balance(date, total:, cash:)
      @account.balances.create!(date: Date.iso8601(date), currency: "USD", balance: BigDecimal(total), cash_balance: BigDecimal(cash),
        start_cash_balance: BigDecimal(cash), start_non_cash_balance: BigDecimal(total) - BigDecimal(cash), flows_factor: 1)
    end

    def trade(amount:, source: nil, quantity: "1", currency: "USD", date: Date.new(2026, 5, 8), **options)
      @account.entries.create!(name: "Test trade", date: date, amount: BigDecimal(amount), currency: currency, source: source,
        entryable: Trade.new(qty: BigDecimal(quantity), price: BigDecimal("10"), currency: currency, security: securities(:aapl)), **options)
    end

    def valuation(date:, amount:, kind:, **options)
      @account.entries.create!(name: "Test valuation", date: Date.iso8601(date), amount: BigDecimal(amount), currency: "USD",
        entryable: Valuation.new(kind: kind), **options)
    end
end
