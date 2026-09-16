require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Ingestion::BalancePolicies::Simplefin::SnapshotTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Snapshot = Ingestion::BalancePolicies::Simplefin::Snapshot

  setup do
    @now = Time.utc(2026, 1, 31)
    Setting.stubs(:[]).returns(nil)
    Setting.stubs(:[]).with("simplefin_cc_overpayment_detection").returns(true)
  end

  test "captured history aggregates all legacy entry kinds and binds the linked family and account" do
    with_provider_encryption do
      connection, external, account = create_link
      8.times { create_entry(account, "20", @now.to_date - 10) }
      2.times { create_entry(account, "-50", @now.to_date - 10) }
      create_entry(account, "999", @now.to_date - 121)
      create_external_account(connection, external_id: "unlinked")

      snapshots = Snapshot.build(connection: connection, observed_at: @now)
      captured = snapshots.fetch(external.external_id)

      assert_equal [ external.external_id ], snapshots.keys
      assert_equal account.id, captured.fetch("account_id")
      assert_equal account.family_id, captured.fetch("family_id")
      assert_equal external.id, captured.fetch("external_account_id")
      assert_equal "CreditCard", captured.fetch("account_type")
      assert_equal @now.iso8601(9), captured.fetch("as_of")
      assert_equal({ "tx_count" => 10, "charges_total" => BigDecimal("160"),
        "payments_total" => BigDecimal("100"), "payments_count" => 2, "recent_payment" => false }, captured.fetch("entry_metrics"))
      assert_nil captured.fetch("raw_metrics")
      assert_equal :debt, Ingestion::BalancePolicies::Simplefin.new(snapshot: captured).call(observed_balance: "-60").classification
    end
  end

  test "disabled detection skips history and settings retain legacy positive sticky expiry defaults" do
    with_provider_encryption do
      connection, external, = create_link
      Setting.stubs(:[]).with("simplefin_cc_overpayment_detection").returns(false)
      Setting.stubs(:[]).with("simplefin_cc_overpayment_sticky_days").returns("0")
      Setting.stubs(:[]).with("simplefin_cc_overpayment_statement_guard_days").returns("0")

      captured = Snapshot.build(connection: connection, observed_at: @now.to_datetime).fetch(external.external_id)

      assert_equal false, captured.fetch("enabled")
      assert_nil captured.fetch("entry_metrics")
      assert_nil captured.fetch("raw_metrics")
      assert_equal 7, captured.fetch("settings").fetch("sticky_days")
      assert_equal 0, captured.fetch("settings").fetch("statement_guard_days")
    end
  end

  test "encrypted classifier state remains authoritative even after expiry" do
    with_provider_encryption do
      connection, external, = create_link
      external.update!(sensitive_details: { "balance_policy_state" => {
        "simplefin" => { "value" => "credit", "expires_at" => (@now + 1.day).iso8601(9) }
      } })
      Provider::AccountData::Simplefin::RetainedHint.expects(:read).never

      captured = Snapshot.build(connection: connection, observed_at: @now).fetch(external.external_id)

      assert_equal "encrypted_state", captured.fetch("sticky_hint_source")
      assert_equal({ "value" => "credit", "expires_at" => (@now + 1.day).iso8601(9) }, captured.fetch("sticky_hint"))
      assert_nil captured.fetch("entry_metrics")
      external.update!(sensitive_details: { "balance_policy_state" => {
        "simplefin" => { "value" => "debt", "expires_at" => (@now - 1.day).iso8601 }
      } })
      Setting.stubs(:[]).with("simplefin_cc_overpayment_detection").returns(false)
      expired = Snapshot.build(connection: connection, observed_at: @now).fetch(external.external_id)
      assert_equal "encrypted_state", expired.fetch("sticky_hint_source")
      assert_equal "debt", expired.fetch("sticky_hint").fetch("value")
      assert_equal (@now - 1.day).iso8601, expired.fetch("sticky_hint").fetch("expires_at")
      assert_provider_column_encrypted(external, :sensitive_details, "balance_policy_state")
    end
  end

  test "raw fallback reads verified migration evidence and replaces old observations with current retained sources" do
    with_provider_encryption do
      # This test isolates raw-history aggregation; quiesced hint admission is
      # covered by RetainedHintTest with an actual archived cache capture.
      Provider::AccountData::Simplefin::RetainedHint.stubs(:read).returns(nil)
      account = create_financial_account
      item = SimplefinItem.create!(family: account.family, name: "Bank connection", access_url: "https://user:secret@bridge.example/access")
      source = item.simplefin_accounts.create!(account_id: "sf-credit", name: "Card", account_type: "credit_card",
        currency: "USD", current_balance: "-60", raw_transactions_payload: [
          { "id" => "updated", "amount" => "-99", "posted" => "2026-01-15" },
          { "id" => "removed", "amount" => "-99", "posted" => "2026-01-15" },
          { "id" => "retained", "amount" => "50", "posted" => "2026-01-14" },
          { "id" => "older", "amount" => "-500", "posted" => "2025-01-01" }
        ])
      AccountProvider.create!(account: account, provider: source)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "simplefin", legacy_item_id: item.id)
      5.times { break if copier.run.shadow? }
      assert copier.control.reload.shadow?
      external = copier.control.provider_connection.external_accounts.sole
      record = Ingestion::Record.transaction(external_id: "simplefin_updated", name: "Charge", amount: BigDecimal("20"),
        currency: "USD", date: Date.new(2026, 1, 12), metadata: { liability_policy_date: "2026-01-15" })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(external.provider_connection, stream: "transactions", external_account: external,
        payload: Ingestion::Codec.dump(page))
      [ [ "simplefin_updated", false ], [ "simplefin_removed", true ] ].each do |id, withdrawn|
        SourceRecord.create!(family: account.family, account: account, external_account: external,
          ingestion_batch: batch, kind: "transaction", external_id: id, withdrawn: withdrawn)
      end

      captured = Snapshot.build(connection: external.provider_connection, observed_at: @now).fetch("sf-credit")

      assert_equal 0, captured.fetch("entry_metrics").fetch("tx_count")
      assert_equal({ "tx_count" => 2, "charges_total" => BigDecimal("20"),
        "payments_total" => BigDecimal("50"), "payments_count" => 1, "recent_payment" => false }, captured.fetch("raw_metrics"))
      refute_includes captured.to_json, "raw_transactions_payload"
      refute_includes captured.to_json, "simplefin_updated"
    end
  end

  private
    def create_financial_account
      families(:dylan_family).accounts.create!(name: "Isolated policy card", currency: "USD", balance: 0,
        accountable: CreditCard.new, owner: users(:family_admin))
    end

    def create_link
      account = create_financial_account
      connection = create_provider_connection(provider_key: "simplefin", credentials: { "access_url" => "private-access" })
      external = create_external_account(connection, external_id: "sf-credit", name: "Card", current_balance: "-60")
      AccountProvider.create!(account: account, external_account: external)
      [ connection, external, account ]
    end

    def create_entry(account, amount, date)
      account.entries.create!(name: "Observed entry", amount: amount, currency: "USD", date: date,
        entryable: Transaction.new)
    end

end
