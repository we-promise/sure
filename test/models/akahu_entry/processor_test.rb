require "test_helper"

class AkahuEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = AkahuAccount.create!(
      akahu_item: @akahu_item,
      name: "Test Bank - Everyday",
      account_id: "acc_123",
      currency: "NZD"
    )
    @account = Account.create!(
      family: @family,
      name: "Everyday",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "NZD"
    )

    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "imports Akahu transaction with sign conversion and provider metadata" do
    transaction_data = {
      _id: "tx_123",
      _account: "acc_123",
      date: "2026-01-15T00:00:00.000Z",
      description: "COFFEE SHOP",
      amount: -12.50,
      type: "EFTPOS",
      merchant: { _id: "merchant_1", name: "Coffee Shop", website: "https://coffee.example" },
      category: {
        _id: "cat_1",
        name: "Food & Drink",
        groups: { personal_finance: { name: "Eating Out" } }
      },
      meta: { reference: "REF", particulars: "PART", code: "CODE", other_account: "12-3456-0000000-00" }
    }

    entry = AkahuEntry::Processor.new(transaction_data, akahu_account: @akahu_account).process

    assert_equal "akahu_tx_123", entry.external_id
    assert_equal "akahu", entry.source
    assert_equal BigDecimal("12.5"), entry.amount
    assert_equal "NZD", entry.currency
    assert_equal Date.new(2026, 1, 15), entry.date
    assert_equal "Coffee Shop", entry.name
    assert_equal "COFFEE SHOP | Reference: REF | Particulars: PART | Code: CODE | Other account: 12-3456-0000000-00", entry.notes

    transaction = entry.entryable
    assert_equal false, transaction.pending?
    assert_equal false, transaction.extra.dig("akahu", "pending")
    assert_equal "Food & Drink", transaction.extra.dig("akahu", "category")
    assert_equal "Eating Out", transaction.extra.dig("akahu", "category_group")
    assert_equal "REF", transaction.extra.dig("akahu", "reference")
    assert_equal "Coffee Shop", transaction.merchant.name
  end

  test "marks pending transactions from importer metadata" do
    entry = AkahuEntry::Processor.new(
      {
        _id: "pending_tx_1",
        _account: "acc_123",
        date: "2026-01-15",
        description: "Pending card auth",
        amount: -8.00,
        _pending: true
      },
      akahu_account: @akahu_account
    ).process

    assert entry.entryable.pending?
    assert_equal true, entry.entryable.extra.dig("akahu", "pending")
  end

  test "uses stable temporary external id for id-less pending transactions" do
    transaction_data = {
      _account: "acc_123",
      date: "2026-01-15",
      description: "Pending card auth",
      amount: -8.00,
      merchant: { name: "Cafe" },
      _pending: true
    }

    first_entry = AkahuEntry::Processor.new(transaction_data, akahu_account: @akahu_account).process
    second_entry = AkahuEntry::Processor.new(transaction_data, akahu_account: @akahu_account).process

    assert_match(/^akahu_pending_[a-f0-9]{32}$/, first_entry.external_id)
    assert_equal first_entry.id, second_entry.id
    assert_equal 1, @account.entries.where(source: "akahu").count
  end

  test "converts unix timestamp date using family timezone not UTC" do
    # 2025-07-14 23:30:00 UTC == 2025-07-15 11:30:00 NZST
    @family.update!(timezone: "Pacific/Auckland")

    transaction_data = {
      _id: "tz_nz_test",
      _account: "acc_123",
      date: 1752537000, # 2025-07-14 23:30:00 UTC
      merchant: { name: "Late Night Shop" },
      description: "After midnight",
      amount: -10.00,
      currency: "NZD"
    }

    entry = AkahuEntry::Processor.new(transaction_data, akahu_account: @akahu_account).process

    assert_not_nil entry
    assert_equal Date.new(2025, 7, 15), entry.date
  end
end
