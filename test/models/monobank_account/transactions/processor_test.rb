require "test_helper"

class MonobankAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  MIDDAY_UNIX = 1_767_960_000

  setup do
    @family = families(:empty)
    @family.update!(timezone: "Europe/Kyiv")
    @monobank_item = MonobankItem.create!(family: @family, name: "Monobank", access_token: "tok")
    @monobank_account = MonobankAccount.create!(
      monobank_item: @monobank_item, name: "Black card", account_id: "acc_1", currency: "UAH"
    )
    @account = Account.create!(
      family: @family, name: "Card",
      accountable: Depository.new(subtype: "checking"), balance: 100, currency: "UAH"
    )
    AccountProvider.create!(account: @account, provider: @monobank_account)
  end

  # Importing must not create categories as a side effect: a family that has none
  # (deliberately cleared, or pre-onboarding) keeps none, and transactions stay
  # uncategorised until the user sets up categories themselves.
  test "does not bootstrap default categories during import" do
    assert_equal 0, @family.categories.count, "family starts with no categories"

    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_1", mcc: 5411) ])

    result = MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert result[:success]
    assert_equal 0, @family.categories.reload.count, "import must not create categories"

    entry = @account.entries.find_by(external_id: "monobank_tx_1")
    assert_not_nil entry, "the transaction was still imported"
    assert_nil entry.transaction.category_id, "stays uncategorised when the family has no categories"
  end

  test "applies the category matched from the transaction MCC" do
    @family.categories.bootstrap!

    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_2", mcc: 5411) ])

    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    entry = @account.entries.find_by(external_id: "monobank_tx_2")
    assert_equal "Groceries", entry.transaction.category&.name
  end

  test "leaves transactions with an unmapped MCC uncategorised" do
    @family.categories.bootstrap!

    # 6011 is an ATM cash withdrawal: money movement, deliberately unmapped.
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_3", mcc: 6011) ])

    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    entry = @account.entries.find_by(external_id: "monobank_tx_3")
    assert_nil entry.transaction.category_id
  end

  test "prunes pending entries that are no longer in the stored payload" do
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_hold", hold: true) ])
    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 1, pending_entries.count

    # The hold settled under a different id, so the hold is gone from the payload.
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_settled", hold: false) ])
    result = MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 1, result[:pruned_pending]
    assert_empty pending_entries
    assert_not_nil @account.entries.find_by(external_id: "monobank_tx_settled")
  end

  private

    def transaction(id:, mcc: 5411, hold: false, amount: -4_000)
      {
        "id" => id,
        "account_id" => "acc_1",
        "time" => MIDDAY_UNIX,
        "description" => "Сільпо",
        "mcc" => mcc,
        "hold" => hold,
        "amount" => amount,
        "operationAmount" => amount,
        "currencyCode" => 980
      }
    end

    def pending_entries
      @account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "monobank")
        .where("(transactions.extra -> 'monobank' ->> 'pending')::boolean = true")
    end
end
