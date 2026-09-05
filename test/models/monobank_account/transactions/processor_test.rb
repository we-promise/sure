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

  # Monobank may issue the settled record under a different id than the hold it
  # replaces, so reconciliation has to match them up on amount and date instead. The
  # user's own category and notes live on the pending entry and must survive.
  test "reconciles a hold that settles under a different id" do
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_hold", hold: true) ])
    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 1, pending_entries.count

    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_settled", hold: false) ])
    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    settled = @account.entries.find_by(external_id: "monobank_tx_settled")
    assert_not_nil settled
    assert_equal [ "monobank_tx_hold" ], settled.transaction.extra["auto_claimed_pending_ids"],
                 "the settled record must claim the hold instead of duplicating it"
    assert_empty pending_entries
    assert_equal 1, @account.entries.count, "no orphaned pending entry is left behind"
  end

  test "prunes a hold that was cancelled rather than settled" do
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_hold", hold: true) ])
    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 1, pending_entries.count

    # Nothing settled: the hold simply dropped out of the statement.
    @monobank_account.update!(raw_transactions_payload: [ unrelated_transaction ])
    result = MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 1, result[:pruned_pending]
    assert_empty pending_entries
  end

  # Destroying an entry the user has taken over would take its splits (child entries)
  # and any transfer it belongs to with it, so a stale hold only loses its pending flag.
  test "keeps user-owned pending entries and clears their pending flag instead" do
    @monobank_account.update!(raw_transactions_payload: [ transaction(id: "tx_hold", hold: true) ])
    MonobankAccount::Transactions::Processor.new(@monobank_account).process

    entry = @account.entries.find_by(external_id: "monobank_tx_hold")
    entry.update!(excluded: true)
    entry.mark_user_modified!

    @monobank_account.update!(raw_transactions_payload: [ unrelated_transaction ])
    result = MonobankAccount::Transactions::Processor.new(@monobank_account).process

    assert_equal 0, result[:pruned_pending]
    assert_equal 1, result[:protected_pending]
    assert Entry.exists?(entry.id), "a user-owned entry must never be hard-deleted by the prune"
    assert_empty pending_entries, "it is no longer held, so the pending flag is gone"
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

    # A record that cannot be mistaken for the settled half of the hold above: neither
    # the amount nor the description matches, so no reconciliation claims it.
    def unrelated_transaction
      transaction(id: "tx_other", amount: -12_345).merge("description" => "Нова пошта")
    end

    def pending_entries
      @account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "monobank")
        .where("(transactions.extra -> 'monobank' ->> 'pending')::boolean = true")
    end
end
