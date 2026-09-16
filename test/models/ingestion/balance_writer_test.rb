require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::BalanceWriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "available-credit balances use a known limit without treating remaining credit as debt" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      apply(external, balance: "1250", policy: { credit_card_mode: "available_credit", credit_limit: "2000", cash_balance: "balance", current_anchor: true })
      assert_equal BigDecimal("750"), account.reload.balance
      assert_equal BigDecimal("750"), account.cash_balance
      assert_equal BigDecimal("2000"), account.credit_card.available_credit
      assert_equal BigDecimal("750"), account.valuations.current_anchor.sole.entry.amount
    end
  end

  test "available-credit balance with no known limit preserves the existing debt and cash" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      account.update!(balance: "300", cash_balance: "300")
      account.credit_card.update!(available_credit: nil)
      apply(external, balance: "1250", policy: { credit_card_mode: "available_credit", current_anchor: true })
      assert_equal BigDecimal("300"), account.reload.balance
      assert_equal BigDecimal("300"), account.cash_balance
      assert_nil account.credit_card.available_credit
    end
  end

  test "a manually supplied credit limit is retained and outstanding debt derives remaining credit" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      account.credit_card.update!(available_credit: "2000")
      apply(external, balance: "1250", policy: { credit_card_mode: "available_credit", cash_balance: "balance" })
      assert_equal BigDecimal("750"), account.reload.balance
      apply(external, balance: "600", policy: { credit_card_mode: "outstanding_debt", credit_limit: "2000", cash_balance: "balance" })
      assert_equal BigDecimal("600"), account.reload.balance
      assert_equal BigDecimal("1400"), account.credit_card.reload.available_credit
    end
  end

  test "a credit limit in another currency cannot be used to fabricate debt" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      account.update!(balance: "300", cash_balance: "300", currency: "USD")
      account.credit_card.update!(available_credit: "2000")
      apply(external, balance: "1250", currency: "EUR", policy: { credit_card_mode: "available_credit" })
      assert_equal "USD", account.reload.currency
      assert_equal BigDecimal("300"), account.balance
      assert_equal BigDecimal("2000"), account.credit_card.reload.available_credit
    end
  end

  test "captured overpayment evidence determines liability sign and preserves sticky expiry on replay" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      captured = Time.iso8601("2026-09-12T12:00:00Z")
      snapshot = policy_snapshot(external, as_of: captured)
      snapshot[:entry_metrics] = { tx_count: 12, charges_total: "100", payments_total: "150", payments_count: 3, recent_payment: false }
      page, batch = apply(external, balance: "50", available: "0", evidence: { balance_policy: snapshot },
        policy: { credit_card: "simplefin_overpayment_v1", cash_balance: "balance" })
      assert_equal BigDecimal("-50"), account.reload.balance
      hint = external.reload.sensitive_details.dig("balance_policy_state", "simplefin")
      assert_equal "credit", hint.fetch("value")
      assert_equal (captured + 7.days).iso8601, hint.fetch("expires_at")
      travel_to(captured + 20.days) do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
      end
      assert_equal hint, external.reload.sensitive_details.dig("balance_policy_state", "simplefin")
      assert_provider_column_encrypted(external, :sensitive_details, "balance_policy_state")
    end
  end

  test "retained migration sticky evidence moves into encrypted state without extending its original expiry" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      snapshot = policy_snapshot(external)
      hint = { value: "debt", expires_at: (Time.iso8601(snapshot.fetch(:as_of)) + 2.days).iso8601 }
      snapshot.merge!(sticky_hint: hint, sticky_hint_source: "retained_migration")
      apply(external, balance: "-50", evidence: { balance_policy: snapshot }, policy: { credit_card: "simplefin_overpayment_v1" })
      assert_equal BigDecimal("50"), account.reload.balance
      assert_equal hint.stringify_keys, external.reload.sensitive_details.dig("balance_policy_state", "simplefin")
    end
  end

  test "unknown overpayment classification preserves the provider sign heuristic and loans bypass it" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      snapshot = policy_snapshot(external).merge(enabled: false)
      apply(external, balance: "50", available: "100", evidence: { balance_policy: snapshot }, policy: { credit_card: "simplefin_overpayment_v1" })
      assert_equal BigDecimal("-50"), account.reload.balance

      loan_source, loan = linked_account(:loan)
      apply(loan_source, balance: "-500", policy: { debt_types: [ "Loan" ], debt_transform: "absolute", credit_card: "simplefin_overpayment_v1" })
      assert_equal BigDecimal("500"), loan.reload.balance
    end
  end

  test "balance classifier evidence cannot cross account ownership" do
    with_provider_encryption do
      external, account = linked_account(:credit_card)
      snapshot = policy_snapshot(external).merge(account_id: accounts(:depository).id)
      initial_balance = account.balance
      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(external, balance: "50", evidence: { balance_policy: snapshot }, policy: { credit_card: "simplefin_overpayment_v1" })
      end
      assert_equal initial_balance, account.reload.balance
    end
  end

  test "a delayed completed valuation retains its captured anchor date instead of moving to the retry date" do
    with_provider_encryption do
      external, account = linked_account(:depository)
      observed_date = Date.current - 2
      apply(external, balance: "1250", balance_date: observed_date, policy: { current_anchor: true, anchor_date: "balance_date" })
      anchor = account.valuations.current_anchor.sole.entry
      assert_equal observed_date, anchor.date
      assert_equal BigDecimal("1250"), anchor.amount
      assert_equal BigDecimal("1250"), account.reload.balance
    end
  end

  test "an older staged valuation cannot replace a newer anchor" do
    with_provider_encryption do
      external, account = linked_account(:depository)
      apply(external, balance: "2000", balance_date: Date.current, policy: { current_anchor: true, anchor_date: "balance_date" })
      anchor = account.valuations.current_anchor.sole.entry
      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(external, balance: "1250", balance_date: Date.current - 2, currency: "EUR", policy: { current_anchor: true, anchor_date: "balance_date" })
      end
      assert_equal "USD", account.reload.currency
      assert_equal BigDecimal("2000"), account.balance
      assert_equal Date.current, anchor.reload.date
      assert_equal BigDecimal("2000"), anchor.amount
    end
  end

  test "an explicit balance-date anchor rejects missing or future observation dates" do
    with_provider_encryption do
      external, account = linked_account(:depository)
      [ nil, Date.current + 1 ].each do |date|
        assert_raises(Provider::AccountData::InvalidResponse) do
          apply(external, balance: "1250", balance_date: date, policy: { current_anchor: true, anchor_date: "balance_date" })
        end
      end
      assert_equal BigDecimal("5000"), account.reload.balance
      assert_empty account.valuations.current_anchor
    end
  end

  private
    def linked_account(fixture)
      external = create_external_account(create_provider_connection)
      account = accounts(fixture)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
      [ external, account ]
    end

    def policy_snapshot(external, as_of: Time.current)
      { schema_version: 1, enabled: true, as_of: as_of.iso8601, account_id: external.current_account.id,
        family_id: external.family_id, external_account_id: external.id, account_type: "CreditCard",
        settings: { window_days: 120, min_txns: 10, min_payments: 2, epsilon_base: "0.5", statement_guard_days: 5, sticky_days: 7 } }
    end

    def apply(external, balance:, policy:, available: nil, evidence: {}, currency: "USD", balance_date: nil)
      record = Ingestion::Record.account(external_id: external.external_id, name: external.name, currency: currency,
        balance: BigDecimal(balance), available_balance: available && BigDecimal(available), balance_date: balance_date, metadata: { balance_policy: policy })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, evidence: evidence)
      selection = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "balances")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "balances",
        payload: Ingestion::Codec.dump(page), source_policy_version: selection.id)
      IngestionBatch.transaction { Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page) }
      [ page, batch ]
    end
end
