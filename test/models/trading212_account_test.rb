require "test_helper"

class Trading212AccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @trading212_item = trading212_items(:configured_item)
    @trading212_account = trading212_accounts(:main_account)
  end

  # === Validations ===

  test "validates presence of currency" do
    account = Trading212Account.new(
      trading212_item: @trading212_item,
      name: "Test Account",
      trading212_account_id: "t212_test_1"
      # currency intentionally blank
    )
    assert_not account.valid?
    assert_includes account.errors[:currency], "can't be blank"
  end

  test "validates uniqueness of trading212_account_id within item scope" do
    existing = @trading212_item.trading212_accounts.create!(
      name: "Duplicate",
      trading212_account_id: "t212_duplicate",
      currency: "USD"
    )

    duplicate = @trading212_item.trading212_accounts.build(
      name: "Another Duplicate",
      trading212_account_id: "t212_duplicate",
      currency: "USD"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:trading212_account_id], "has already been taken"
  end

  test "allows nil trading212_account_id across items" do
    second_item = trading212_items(:pending_setup_item)

    account1 = @trading212_item.trading212_accounts.create!(
      name: "Account 1",
      currency: "USD"
    )

    account2 = second_item.trading212_accounts.create!(
      name: "Account 2",
      currency: "USD"
    )

    # Both nil IDs are allowed across different items (unique index has WHERE clause)
    assert account1.valid?
    assert account2.valid?
  end

  # === current_account ===

  test "current_account returns account through account_provider" do
    investment = accounts(:investment)
    @trading212_account.ensure_account_provider!(investment)

    assert_equal investment, @trading212_account.current_account
  end

  test "current_account returns nil when no provider link" do
    assert_nil @trading212_account.current_account
  end

  # === ensure_account_provider! ===

  test "ensure_account_provider! creates AccountProvider for the given account" do
    investment = accounts(:investment)

    assert_difference "AccountProvider.count", 1 do
      @trading212_account.ensure_account_provider!(investment)
    end

    assert_equal investment, @trading212_account.reload.current_account
  end

  test "ensure_account_provider! is idempotent" do
    investment = accounts(:investment)

    assert_difference "AccountProvider.count", 1 do
      @trading212_account.ensure_account_provider!(investment)
    end

    assert_no_difference "AccountProvider.count" do
      @trading212_account.ensure_account_provider!(investment)
    end

    assert_equal investment, @trading212_account.reload.current_account
  end

  test "ensure_account_provider! updates account if different" do
    investment = accounts(:investment)
    @trading212_account.ensure_account_provider!(investment)

    crypto = accounts(:crypto)
    @trading212_account.ensure_account_provider!(crypto)

    assert_equal crypto, @trading212_account.reload.current_account
  end

  # === instruments_map ===

  test "instruments_map delegates to trading212_item" do
    instruments = [
      { "ticker" => "AAPL_US_EQ", "shortName" => "Apple Inc.", "currencyCode" => "USD" }
    ]
    @trading212_item.update!(raw_instruments_payload: instruments)

    result = @trading212_account.instruments_map
    assert_equal "Apple Inc.", result["AAPL_US_EQ"]["shortName"]
  end

  # === belongs_to relationships ===

  test "belongs to trading212_item" do
    assert_equal @trading212_item, @trading212_account.trading212_item
  end

  test "destroyed when trading212_item is destroyed" do
    t212_account_id = @trading212_account.id

    @trading212_item.destroy

    assert_nil Trading212Account.find_by(id: t212_account_id)
  end
end
