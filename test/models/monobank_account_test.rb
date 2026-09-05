require "test_helper"

class MonobankAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @monobank_item = MonobankItem.create!(family: @family, name: "Test Monobank", access_token: "mono-token")
  end

  test "needs_setup excludes linked and ignored accounts" do
    unlinked = MonobankAccount.create!(monobank_item: @monobank_item, name: "Unlinked", account_id: "acc_unlinked", currency: "UAH")
    ignored  = MonobankAccount.create!(monobank_item: @monobank_item, name: "Skipped", account_id: "acc_ignored", currency: "UAH", ignored: true)

    linked = MonobankAccount.create!(monobank_item: @monobank_item, name: "Linked", account_id: "acc_linked", currency: "UAH")
    account = Account.create!(family: @family, name: "Linked", accountable: Depository.new(subtype: "checking"), balance: 0, currency: "UAH")
    AccountProvider.create!(account: account, provider: linked)

    needs_setup = @monobank_item.monobank_accounts.needs_setup

    assert_includes needs_setup, unlinked
    assert_not_includes needs_setup, ignored
    assert_not_includes needs_setup, linked
    assert_equal 1, @monobank_item.unlinked_accounts_count
  end

  # Monobank reports a card's balance *including* its credit limit, so own funds are
  # balance - creditLimit, and both arrive in minor units.
  test "card snapshot subtracts the credit limit and converts minor units" do
    monobank_account = MonobankAccount.new(monobank_item: @monobank_item, account_id: "acc_black")

    monobank_account.upsert_monobank_snapshot!(
      {
        "id" => "acc_black",
        "kind" => "card",
        "type" => "black",
        "balance" => 150_00,
        "creditLimit" => 100_00,
        "currencyCode" => 980,
        "maskedPan" => [ "537541******1234" ],
        "iban" => "UA-TEST-IBAN-SNAPSHOT"
      }
    )

    assert_equal BigDecimal("50"), monobank_account.current_balance
    assert_equal BigDecimal("100"), monobank_account.credit_limit
    assert_equal "UAH", monobank_account.currency
    assert_equal "black", monobank_account.account_type
    assert_equal "card", monobank_account.account_kind
    assert_equal "537541******1234", monobank_account.masked_pan
    assert_equal "Depository", monobank_account.suggested_account_type
    assert_equal "checking", monobank_account.suggested_subtype
  end

  test "card name combines the localized product name with the last four digits" do
    monobank_account = MonobankAccount.new(monobank_item: @monobank_item, account_id: "acc_white")

    monobank_account.upsert_monobank_snapshot!(
      { "id" => "acc_white", "kind" => "card", "type" => "white", "balance" => 0, "currencyCode" => 980, "maskedPan" => [ "444111******9876" ] }
    )

    assert_equal "White card ·9876", monobank_account.name
  end

  test "unknown card types still produce a name and no type suggestion" do
    monobank_account = MonobankAccount.new(monobank_item: @monobank_item, account_id: "acc_new")

    monobank_account.upsert_monobank_snapshot!(
      { "id" => "acc_new", "kind" => "card", "type" => "titanium", "balance" => 0, "currencyCode" => 980 }
    )

    assert_equal "Monobank card", monobank_account.name
    assert_nil monobank_account.suggested_account_type
  end

  test "jar snapshot uses its title and maps to savings" do
    monobank_account = MonobankAccount.new(monobank_item: @monobank_item, account_id: "jar_1")

    monobank_account.upsert_monobank_snapshot!(
      { "id" => "jar_1", "kind" => "jar", "title" => "На тепловізор", "balance" => 10_000_00, "currencyCode" => 980, "goal" => 100_000_00 }
    )

    assert_equal "На тепловізор", monobank_account.name
    assert monobank_account.jar?
    assert_equal "jar", monobank_account.account_type
    assert_equal BigDecimal("10000"), monobank_account.current_balance
    assert_equal "savings", monobank_account.suggested_subtype
  end

  test "non-UAH accounts resolve their currency from the ISO numeric code" do
    monobank_account = MonobankAccount.new(monobank_item: @monobank_item, account_id: "acc_usd")

    monobank_account.upsert_monobank_snapshot!(
      { "id" => "acc_usd", "kind" => "card", "type" => "black", "balance" => 5_00, "currencyCode" => 840 }
    )

    assert_equal "USD", monobank_account.currency
    assert_equal BigDecimal("5"), monobank_account.current_balance
  end
end
