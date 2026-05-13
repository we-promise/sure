# frozen_string_literal: true

require "test_helper"

class BrexEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @brex_item = brex_items(:one)
    @account = @family.accounts.create!(
      name: "Brex Card",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    @brex_account = @brex_item.brex_accounts.create!(
      account_id: BrexAccount.card_account_id,
      account_kind: "card",
      name: "Brex Card",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: @account, provider: @brex_account)
  end

  test "imports card purchase with Brex signed amount preserved" do
    entry = BrexEntry::Processor.new(card_transaction(amount: 12_34), brex_account: @brex_account).process

    assert_equal BigDecimal("12.34"), entry.amount
    assert_equal "USD", entry.currency
    assert_equal "brex", entry.source
    assert_equal Date.new(2026, 1, 2), entry.date
    assert_equal "STAPLES", entry.transaction.merchant.name
    assert_equal "card_1", entry.transaction.extra.dig("brex", "card_id")
    assert_equal "STAPLES", entry.transaction.extra.dig("brex", "merchant", "raw_descriptor")
    refute_includes entry.transaction.extra.dig("brex", "merchant").to_s, "test-pan-placeholder"
    refute_includes entry.transaction.extra.dig("brex", "merchant").to_s, "pan"
  end

  test "imports card payment as negative amount" do
    entry = BrexEntry::Processor.new(card_transaction(id: "tx_payment", amount: -50_00, type: "COLLECTION"), brex_account: @brex_account).process

    assert_equal BigDecimal("-50.0"), entry.amount
    assert_equal "cc_payment", entry.transaction.kind
  end

  test "is idempotent by external id and source" do
    transaction = card_transaction(id: "tx_duplicate", amount: 12_34)

    assert_difference -> { @account.entries.where(source: "brex", external_id: "brex_tx_duplicate").count }, 1 do
      BrexEntry::Processor.new(transaction, brex_account: @brex_account).process
      BrexEntry::Processor.new(transaction, brex_account: @brex_account).process
    end
  end

  test "tolerates nullable Brex fields and unknown types" do
    transaction = {
      id: "tx_nullable",
      amount: nil,
      description: "Cash movement",
      posted_at_date: "2026-01-03",
      initiated_at_date: "2026-01-02",
      type: "NEW_BREX_TYPE"
    }

    entry = BrexEntry::Processor.new(transaction, brex_account: @brex_account).process

    assert_equal BigDecimal("0"), entry.amount
    assert_equal "Cash movement", entry.name
    assert_equal "NEW_BREX_TYPE", entry.transaction.extra.dig("brex", "type")
  end

  test "uses localized default transaction name" do
    transaction = card_transaction(id: "tx_default_name", amount: 12_34)
    transaction.delete(:description)
    transaction.delete(:merchant)

    entry = BrexEntry::Processor.new(transaction, brex_account: @brex_account).process

    assert_equal I18n.t("brex_items.entries.default_name"), entry.name
  end

  test "logs validation failure without re-reading missing external id" do
    Rails.logger.expects(:error).with(regexp_matches(/Validation error for transaction brex_unknown/)).once

    assert_raises(ArgumentError) do
      BrexEntry::Processor.new(card_transaction(id: nil, amount: 12_34), brex_account: @brex_account).process
    end
  end

  test "logs save failure with cached external id" do
    Account::ProviderImportAdapter.any_instance
                                  .expects(:import_transaction)
                                  .raises(ActiveRecord::RecordInvalid.new(Entry.new))
    Rails.logger.expects(:error).with(regexp_matches(/Failed to save transaction brex_tx_save_failure/)).once

    assert_raises(StandardError) do
      BrexEntry::Processor.new(card_transaction(id: "tx_save_failure", amount: 12_34), brex_account: @brex_account).process
    end
  end

  test "logs missing transaction currency before using account fallback" do
    Rails.logger.expects(:warn).with(regexp_matches(/Invalid Brex currency nil for transaction tx_missing_currency/)).once

    entry = BrexEntry::Processor.new(
      card_transaction(id: "tx_missing_currency", amount: 12_34).tap { |transaction| transaction[:amount].delete(:currency) },
      brex_account: @brex_account
    ).process

    assert_equal "USD", entry.currency
  end

  private

    def card_transaction(id: "tx_1", amount:, type: "CARD_EXPENSE")
      {
        id: id,
        amount: { amount: amount, currency: "USD" },
        description: "Office supplies",
        posted_at_date: "2026-01-02",
        initiated_at_date: "2026-01-01",
        type: type,
        card_id: "card_1",
        merchant: {
          raw_descriptor: "STAPLES",
          card_metadata: {
            pan: "test-pan-placeholder"
          }
        }
      }
    end
end
