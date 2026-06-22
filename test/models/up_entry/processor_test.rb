require "test_helper"

class UpEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @up_item = UpItem.create!(
      family: @family,
      name: "Test Up",
      access_token: "up-access-token"
    )
    @up_account = UpAccount.create!(
      up_item: @up_item,
      name: "Up Spending",
      account_id: "acc_123",
      currency: "AUD"
    )
    @account = Account.create!(
      family: @family,
      name: "Spending",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "AUD"
    )

    AccountProvider.create!(account: @account, provider: @up_account)
  end

  test "imports settled Up transaction with sign conversion and provider metadata" do
    transaction_data = {
      id: "tx_123",
      account_id: "acc_123",
      status: "SETTLED",
      description: "Coffee Shop",
      message: "Morning coffee",
      rawText: "COFFEE SHOP SYDNEY",
      amount: { currencyCode: "AUD", value: "-12.50", valueInBaseUnits: -1250 },
      foreignAmount: nil,
      settledAt: "2026-01-15T08:30:00+11:00",
      createdAt: "2026-01-15T08:00:00+11:00",
      category_id: "restaurants-and-cafes"
    }

    entry = UpEntry::Processor.new(transaction_data, up_account: @up_account).process

    assert_equal "up_tx_123", entry.external_id
    assert_equal "up", entry.source
    assert_equal BigDecimal("12.5"), entry.amount
    assert_equal "AUD", entry.currency
    assert_equal Date.new(2026, 1, 15), entry.date
    assert_equal "Coffee Shop", entry.name
    assert_equal "Morning coffee", entry.notes

    transaction = entry.entryable
    assert_equal false, transaction.pending?
    assert_equal false, transaction.extra.dig("up", "pending")
    assert_equal "SETTLED", transaction.extra.dig("up", "status")
    assert_equal "restaurants-and-cafes", transaction.extra.dig("up", "category_id")
    assert_equal "Coffee Shop", transaction.merchant.name
  end

  test "marks HELD transactions as pending and falls back to createdAt for the date" do
    entry = UpEntry::Processor.new(
      {
        id: "tx_held_1",
        account_id: "acc_123",
        status: "HELD",
        description: "Pending card auth",
        amount: { currencyCode: "AUD", value: "-8.00", valueInBaseUnits: -800 },
        settledAt: nil,
        createdAt: "2026-01-20T12:00:00+11:00"
      },
      up_account: @up_account
    ).process

    assert entry.entryable.pending?
    assert_equal true, entry.entryable.extra.dig("up", "pending")
    assert_equal Date.new(2026, 1, 20), entry.date
  end

  test "stores foreign amount FX metadata" do
    entry = UpEntry::Processor.new(
      {
        id: "tx_fx_1",
        account_id: "acc_123",
        status: "SETTLED",
        description: "US Merchant",
        amount: { currencyCode: "AUD", value: "-15.00", valueInBaseUnits: -1500 },
        foreignAmount: { currencyCode: "USD", value: "-10.00", valueInBaseUnits: -1000 },
        settledAt: "2026-01-18T00:00:00+11:00",
        createdAt: "2026-01-18T00:00:00+11:00"
      },
      up_account: @up_account
    ).process

    transaction = entry.entryable
    assert_equal "USD", transaction.extra.dig("up", "fx_from")
    assert_equal "-10.00", transaction.extra.dig("up", "fx_amount")
  end

  test "income (positive Up amount) is stored as negative in Sure" do
    entry = UpEntry::Processor.new(
      {
        id: "tx_income_1",
        account_id: "acc_123",
        status: "SETTLED",
        description: "Salary",
        amount: { currencyCode: "AUD", value: "2500.00", valueInBaseUnits: 250000 },
        settledAt: "2026-01-15T00:00:00+11:00",
        createdAt: "2026-01-15T00:00:00+11:00"
      },
      up_account: @up_account
    ).process

    assert_equal BigDecimal("-2500.0"), entry.amount
  end
end
