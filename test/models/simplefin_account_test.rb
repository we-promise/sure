require "test_helper"

class SimplefinAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Connection",
      access_url: "https://example.com/access_token"
    )
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "Test Checking Account",
      account_id: "test_checking_123",
      currency: "USD",
      account_type: "checking",
      current_balance: 1500.50
    )
  end

  test "belongs to simplefin_item" do
    assert_equal @simplefin_item, @simplefin_account.simplefin_item
  end

  test "validates presence of required fields" do
    account = SimplefinAccount.new
    refute account.valid?

    assert_includes account.errors[:name], "can't be blank"
    assert_includes account.errors[:account_type], "can't be blank"
    assert_includes account.errors[:currency], "can't be blank"
  end

  test "validates balance presence" do
    account = SimplefinAccount.new(
      simplefin_item: @simplefin_item,
      name: "No Balance Account",
      account_id: "no_balance_123",
      currency: "USD",
      account_type: "checking"
    )

    refute account.valid?
    assert_includes account.errors[:base], "SimpleFin account must have either current or available balance"
  end

  test "can upsert snapshot data" do
    balance_date = "2024-01-15T10:30:00Z"
    snapshot = {
      "balance" => 2000.0,
      "available-balance" => 1800.0,
      "balance-date" => balance_date,
      "currency" => "USD",
      "type" => "savings",
      "subtype" => "savings",
      "name" => "Updated Savings Account",
      "id" => "updated_123",
      "extra" => { "account_number_last_4" => "1234" },
      "org" => { "domain" => "testbank.com", "name" => "Test Bank" }
    }

    @simplefin_account.upsert_simplefin_snapshot!(snapshot)

    assert_equal BigDecimal("2000.0"), @simplefin_account.current_balance
    assert_equal BigDecimal("1800.0"), @simplefin_account.available_balance
    assert_equal Time.parse(balance_date), @simplefin_account.balance_date
    assert_equal "savings", @simplefin_account.account_type
    assert_equal "Updated Savings Account", @simplefin_account.name
    assert_equal({ "account_number_last_4" => "1234" }, @simplefin_account.extra)
    assert_equal({ "domain" => "testbank.com", "name" => "Test Bank" }, @simplefin_account.org_data)
    assert_equal snapshot, @simplefin_account.raw_payload
  end

  test "can upsert transactions" do
    transactions = [
      { "id" => "txn_1", "amount" => -50.00, "description" => "Coffee Shop", "posted" => "2024-01-01" },
      { "id" => "txn_2", "amount" => 1000.00, "description" => "Paycheck", "posted" => "2024-01-02" }
    ]

    @simplefin_account.upsert_simplefin_transactions_snapshot!(transactions)

    assert_equal transactions, @simplefin_account.raw_transactions_payload
  end
end
