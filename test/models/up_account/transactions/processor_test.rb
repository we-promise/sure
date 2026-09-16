require "test_helper"

class UpAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @up_item = UpItem.create!(family: @family, name: "Up", access_token: "tok")
    @up_account = UpAccount.create!(
      up_item: @up_item, name: "Spending", account_id: "acc_1", currency: "AUD"
    )
    @account = Account.create!(
      family: @family, name: "Spending",
      accountable: Depository.new(subtype: "checking"), balance: 100, currency: "AUD"
    )
    AccountProvider.create!(account: @account, provider: @up_account)
  end

  # Importing must not create categories as a side effect: a family that has none
  # (deliberately cleared, or pre-onboarding) keeps none, and transactions stay
  # uncategorised until the user sets up categories themselves.
  test "does not bootstrap default categories during import" do
    assert_equal 0, @family.categories.count, "family starts with no categories"

    @up_account.update!(raw_transactions_payload: [
      {
        "id" => "tx_1",
        "status" => "SETTLED",
        "description" => "Woolworths",
        "amount" => { "currencyCode" => "AUD", "value" => "-40.00", "valueInBaseUnits" => -4000 },
        "settledAt" => "2026-01-15T00:00:00+11:00",
        "createdAt" => "2026-01-15T00:00:00+11:00",
        "account_id" => "acc_1",
        "category_id" => "groceries"
      }
    ])

    result = UpAccount::Transactions::Processor.new(@up_account).process

    assert result[:success]
    assert_equal 0, @family.categories.reload.count, "import must not create categories"

    entry = @account.entries.find_by(external_id: "up_tx_1")
    assert_not_nil entry, "the transaction was still imported"
    assert_nil entry.transaction.category_id, "stays uncategorised when the family has no categories"
  end

  # With the default categories present, the same Up category resolves and is applied.
  test "applies matched categories when the family already has them" do
    @family.categories.bootstrap!

    @up_account.update!(raw_transactions_payload: [
      {
        "id" => "tx_2",
        "status" => "SETTLED",
        "description" => "Woolworths",
        "amount" => { "currencyCode" => "AUD", "value" => "-40.00", "valueInBaseUnits" => -4000 },
        "settledAt" => "2026-01-15T00:00:00+11:00",
        "createdAt" => "2026-01-15T00:00:00+11:00",
        "account_id" => "acc_1",
        "category_id" => "groceries"
      }
    ])

    UpAccount::Transactions::Processor.new(@up_account).process

    entry = @account.entries.find_by(external_id: "up_tx_2")
    assert_equal "Groceries", entry.transaction.category&.name
  end
end
