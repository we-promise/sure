require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::ActivityWriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "trade retries preserve financial identity and user protection" do
    with_provider_encryption do
      external, account = linked_investment
      security = securities(:aapl)
      record = Ingestion::Record.activity(external_id: "trade-buy", name: "Buy Apple", date: Date.current,
        amount: BigDecimal("50"), currency: "USD", activity_type: "buy",
        quantity: BigDecimal("0.5"), price: BigDecimal("100"), security: { ticker: "AAPL" })
      apply(external, record, security: security)
      entry = account.entries.find_by!(external_id: "trade-buy")
      assert_equal BigDecimal("0.5"), entry.trade.qty
      assert_equal entry.id, SourceRecord.find_by!(external_account: external, kind: "activity").entry.id
      entry.update!(user_modified: true, name: "My trade note")
      revised = Ingestion::Record.activity(**record.attributes.merge(amount: BigDecimal("70"), quantity: BigDecimal("0.7")))

      assert_no_difference [ "Entry.count", "Trade.count", "EntrySource.count" ] do
        apply(external, revised, security: security)
      end
      assert_equal "My trade note", entry.reload.name
      assert_equal BigDecimal("50"), entry.amount
      assert_equal BigDecimal("0.5"), entry.trade.qty
    end
  end

  test "cash dividends use transaction reconciliation and retain investment classification" do
    with_provider_encryption do
      external, account = linked_investment
      record = Ingestion::Record.activity(external_id: "cash-dividend", name: "Dividend", date: Date.current,
        amount: BigDecimal("-12.45"), currency: "USD", activity_type: "dividend")
      apply(external, record)
      entry = account.entries.find_by!(external_id: "cash-dividend")

      assert entry.transaction?
      assert_equal "Dividend", entry.transaction.investment_activity_label
      assert_equal BigDecimal("-12.45"), entry.amount
      assert_equal "activity", entry.entry_sources.first.source_record.kind
      assert_no_difference "Entry.count" do
        apply(external, record)
      end
    end
  end

  test "insert-only trade observations preserve financial details and repair only an unprotected missing label" do
    with_provider_encryption do
      external, account = linked_investment
      security = securities(:aapl)
      record = Ingestion::Record.activity(external_id: "insert-only-trade", name: "Buy Apple", date: Date.current,
        amount: BigDecimal("-50"), currency: "USD", activity_type: "buy",
        quantity: BigDecimal("0.5"), price: BigDecimal("100"), security: { ticker: "AAPL" },
        metadata: { update_policy: "insert_only", repair_activity_label: true, notes: "Paid from wallet", fee: BigDecimal("0.12") })
      apply(external, record, security: security)
      entry = account.entries.find_by!(external_id: "insert-only-trade")
      assert_equal "Paid from wallet", entry.notes
      assert_equal BigDecimal("0.12"), entry.trade.fee
      entry.trade.update!(investment_activity_label: nil)
      revised = Ingestion::Record.activity(**record.attributes.merge(amount: BigDecimal("-75"), quantity: BigDecimal("0.75")))

      assert_no_difference [ "Entry.count", "Trade.count", "EntrySource.count" ] do
        apply(external, revised, security: security)
      end
      assert_equal BigDecimal("-50"), entry.reload.amount
      assert_equal BigDecimal("0.5"), entry.trade.qty
      assert_equal "Buy", entry.trade.investment_activity_label
      assert_equal "Paid from wallet", entry.notes

      entry.update!(user_modified: true)
      entry.trade.update!(investment_activity_label: nil)
      apply(external, revised, security: security)
      assert_nil entry.trade.reload.investment_activity_label
    end
  end

  test "paired activities commit together and cannot recreate a missing legacy or deleted leg" do
    with_provider_encryption do
      external, account = linked_investment
      records = paired_activities
      assert_difference "Entry.count", 2 do
        apply(external, records, security: securities(:aapl))
      end
      trade = account.entries.find_by!(external_id: "pair-trade")
      funding = account.entries.find_by!(external_id: "pair-funding")
      assert trade.trade?
      assert funding.transaction?
      funding.destroy!
      assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count" ] do
        apply(external, records, security: securities(:aapl))
      end
      assert_equal trade.id, account.entries.find_by!(external_id: "pair-trade").id
      assert_nil account.entries.find_by(external_id: "pair-funding")
      assert_nil SourceRecord.find_by!(external_account: external, external_id: "pair-funding").entry
    end
  end

  test "activity meaning does not change a provider's explicit trade representation" do
    with_provider_encryption do
      external, account = linked_investment
      record = Ingestion::Record.activity(external_id: "legacy-dividend-trade", name: "Dividend", date: Date.current,
        amount: BigDecimal("0"), currency: "USD", activity_type: "dividend", ledger_type: "trade",
        quantity: BigDecimal("0"), price: BigDecimal("0"), security: { ticker: "AAPL" },
        metadata: { allow_zero_quantity: true, investment_activity_label: "Dividend" })
      apply(external, record, security: securities(:aapl))
      entry = account.entries.find_by!(external_id: "legacy-dividend-trade")
      assert entry.trade?
      assert_equal "Dividend", entry.trade.investment_activity_label
      assert_equal BigDecimal("0"), entry.trade.qty
      assert_no_difference "Entry.count" do
        apply(external, record, security: securities(:aapl))
      end
    end
  end

  test "a zero-quantity trade requires an explicit representation policy" do
    with_provider_encryption do
      external, = linked_investment
      record = Ingestion::Record.activity(external_id: "ambiguous-zero", name: "Dividend", date: Date.current,
        amount: BigDecimal("0"), currency: "USD", activity_type: "dividend", ledger_type: "trade",
        quantity: BigDecimal("0"), price: BigDecimal("0"), security: { ticker: "AAPL" })
      assert_raises(Provider::AccountData::InvalidResponse) { apply(external, record, security: securities(:aapl)) }
    end
  end

  test "a page missing one atomic financial leg cannot partially post" do
    with_provider_encryption do
      external, = linked_investment
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::InvalidResponse) do
          apply(external, paired_activities.first, security: securities(:aapl))
        end
      end
    end
  end

  test "trade metadata merges its provider namespace and respects user protection" do
    with_provider_encryption do
      external, account = linked_investment
      record = Ingestion::Record.activity(external_id: "metadata-trade", name: "Buy Apple", date: Date.current,
        amount: BigDecimal("50"), currency: "USD", activity_type: "buy", quantity: BigDecimal("0.5"),
        price: BigDecimal("100"), security: { ticker: "AAPL" }, metadata: { extra: { up: { event_id: "event-1", fees: "0.25" } } })
      apply(external, record, security: securities(:aapl))
      entry = account.entries.find_by!(external_id: "metadata-trade")
      entry.trade.update!(extra: entry.trade.extra.merge("user_note" => "Keep this"))
      apply(external, record, security: securities(:aapl))
      assert_equal "Keep this", entry.trade.reload.extra.fetch("user_note")
      assert_equal "event-1", entry.trade.extra.dig("up", "event_id")
      assert_equal BigDecimal("50"), entry.reload.amount

      entry.update!(user_modified: true)
      changed = Ingestion::Record.activity(**record.attributes.merge(metadata: { extra: { up: { event_id: "event-2" } } }))
      apply(external, changed, security: securities(:aapl))
      assert_equal "event-1", entry.trade.reload.extra.dig("up", "event_id")
    end
  end

  private
    def paired_activities
      metadata = { update_policy: "insert_only", atomic_group: { id: "pair", policy: "insert_pair_if_absent",
        members: [ { external_id: "pair-trade", financial_type: "Trade" }, { external_id: "pair-funding", financial_type: "Transaction" } ] } }
      [
        Ingestion::Record.activity(external_id: "pair-trade", name: "Buy Apple", date: Date.current,
          amount: BigDecimal("50"), currency: "USD", activity_type: "buy", quantity: BigDecimal("0.5"),
          price: BigDecimal("100"), security: { ticker: "AAPL" }, metadata: metadata),
        Ingestion::Record.activity(external_id: "pair-funding", name: "Funding", date: Date.current,
          amount: BigDecimal("-50"), currency: "USD", activity_type: "contribution", metadata: metadata)
      ]
    end

    def linked_investment
      external = create_external_account(create_provider_connection)
      account = accounts(:investment)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "activities")
      [ external, account ]
    end

    def apply(external, record, security: nil)
      records = Array(record)
      page = Provider::AccountData::Page.new(records: records, complete: true)
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "activities")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "activities",
        payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      IngestionBatch.transaction do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch,
          securities: security ? records.select { |item| item[:security] }.to_h { |item| [ [ "activity", item[:external_id] ], security ] } : {}).apply(page)
      end
    end
end
