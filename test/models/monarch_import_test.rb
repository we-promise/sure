require "test_helper"

class MonarchImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @import = @family.imports.create!(type: "MonarchImport")
    @import.attach_exports!(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read
    )
  end

  test "attaching the exports suggests a choice for every account" do
    mappings = @import.ordered_account_mappings

    assert_equal [ "Checking", "Card", "Old Savings" ], mappings.map(&:key)
    assert_equal %w[Depository CreditCard Investment], mappings.map(&:type)
    assert @import.publishable?
  end

  test "an invalid choice stops the import from being publishable" do
    mapping("Checking").update_column(:value, { "type" => "Boat" })

    assert_not @import.reload.publishable?
  end

  test "Sure's recalculated balances match the Monarch history" do
    mapping("Old Savings").update!(choices: { "closed" => true })
    publish!

    history = monarch_history
    { "Checking" => 1, "Card" => -1, "Old Savings" => 1 }.each do |name, sign|
      account = @family.accounts.find_by!(name: name)
      assert_balances_match history[name], account, sign
    end

    old_savings = @family.accounts.find_by!(name: "Old Savings")
    assert old_savings.disabled?
    assert_equal 0, old_savings.balances.find_by(date: Date.new(2024, 1, 2)).balance
    assert_equal 4, @family.entries.where(entryable_type: "Transaction").count
  end

  test "importing into an existing account keeps it, reproduces the history and reverts cleanly" do
    account = @family.accounts.create!(name: "My Checking", balance: 500, currency: "USD", accountable: Depository.new)
    opening = account.entries.create!(date: Date.new(2024, 1, 3), amount: 500, currency: "USD", name: "Opening balance",
      entryable: Valuation.new(kind: "opening_anchor"))
    mapping("Checking").update!(mappable: account)
    publish!

    assert_not @family.accounts.exists?(name: "Checking")
    assert_equal Date.new(2024, 1, 1), opening.reload.date
    assert_balances_match monarch_history["Checking"], account, 1

    @import.revert
    assert @import.reload.pending?
    assert @family.accounts.exists?(account.id)
    assert_equal [ Date.new(2024, 1, 3), 500 ], [ opening.reload.date, opening.amount ]
    assert_equal [ opening.id ], account.entries.pluck(:id)
  end

  test "only a move of an opening balance is still worth publishing, and counts as committed" do
    account = @family.accounts.create!(name: "My Checking", balance: 500, currency: "USD", accountable: Depository.new)
    account.entries.create!(date: Date.new(2024, 1, 3), amount: 500, currency: "USD", name: "Opening balance",
      entryable: Valuation.new(kind: "opening_anchor"))
    mapping("Checking").update!(mappable: account)

    assert @import.changes_existing_records?
    assert_not @import.data_committed?
    publish!
    @import.entries.delete_all
    assert @import.reload.data_committed?
  end

  test "publishing needs write access to the existing accounts it imports into" do
    account = @family.accounts.create!(name: "Private", balance: 0, currency: "USD", accountable: Depository.new, owner: users(:empty))
    mapping("Checking").update!(mappable: account)

    assert_equal [ account.id ], @import.preexisting_target_account_ids
    assert @import.accounts_writable_by?(users(:empty))
    assert_not @import.accounts_writable_by?(users(:josh))
  end

  test "an existing account marked closed is disabled, and enabled again on undo" do
    account = @family.accounts.create!(name: "My Savings", balance: 10, currency: "USD", accountable: Depository.new)
    mapping("Old Savings").update!(mappable: account, choices: { "closed" => true })
    publish!

    assert account.reload.disabled?
    @import.revert
    assert account.reload.active?
  end

  test "deleting a published import puts a moved opening balance back" do
    account = @family.accounts.create!(name: "My Checking", balance: 500, currency: "USD", accountable: Depository.new)
    opening = account.entries.create!(date: Date.new(2024, 1, 3), amount: 500, currency: "USD", name: "Opening balance",
      entryable: Valuation.new(kind: "opening_anchor"))
    mapping("Checking").update!(mappable: account)
    publish!

    @import.destroy!
    assert_equal [ Date.new(2024, 1, 3), 500 ], [ opening.reload.date, opening.amount ]
  end

  test "an unchanged balance is compared with what the form showed for the saved destination" do
    loan = @family.accounts.create!(name: "My Loan", balance: 0, currency: "USD", accountable: Loan.new)
    mapping("Checking").update!(mappable: loan)
    shown = @import.suggested_current_balance(mapping("Checking"))

    @import.apply_account_choices!(
      { mapping("Checking").id => { type: "Depository", include: "1", target_id: loan.id, current_balance: shown } },
      target_accounts: @family.accounts
    )

    assert_nil mapping("Checking").current_balance
  end

  test "renamed accounts are created with the new name" do
    @import.apply_account_choices!(
      { mapping("Checking").id => { name: "Everyday", type: "Depository", include: "1", transactions: "1" } },
      target_accounts: @family.accounts
    )
    publish!

    assert @family.accounts.exists?(name: "Everyday")
    assert_not @family.accounts.exists?(name: "Checking")
  end

  test "an unchanged or blank name keeps Monarch's" do
    @import.apply_account_choices!(
      { mapping("Checking").id => { name: "Checking", type: "Depository", include: "1" },
        mapping("Card").id => { name: " ", type: "CreditCard", include: "1" } },
      target_accounts: @family.accounts
    )

    assert_nil mapping("Checking").choices["name"]
    assert_equal "Card", mapping("Card").account_name
  end

  test "importing the same exports into the accounts they created skips every transaction" do
    publish!
    second = @family.imports.create!(type: "MonarchImport")
    second.attach_exports!(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read
    )
    %w[Checking Card Old\ Savings].each do |name|
      second.account_mappings.find_by!(key: name).update!(mappable: @family.accounts.find_by!(name: name))
    end

    assert_no_difference -> { @family.entries.where(entryable_type: "Transaction").count } do
      second.reload.publish
    end
    assert second.reload.complete?, second.error
    assert_balances_match monarch_history["Checking"], @family.accounts.find_by!(name: "Checking"), 1
  end

  # Provider handoff: an account imported from Monarch and later linked to a
  # bank connection. The sync claims the imported transaction instead of adding
  # a copy, keeps what Monarch imported, and a repeat Monarch import still
  # recognises it by its Monarch ID.
  test "a later provider sync claims imported transactions instead of duplicating them" do
    publish!
    checking = @family.accounts.find_by!(name: "Checking")
    imported = checking.entries.find_by!(name: "Grocer")
    transactions_before = checking.entries.where(entryable_type: "Transaction").count

    synced = Account::ProviderImportAdapter.new(checking).import_transaction(
      external_id: "sfin-1", amount: 10, currency: "USD", date: Date.new(2024, 1, 2), name: "GROCER #12 POS", source: "simplefin"
    )

    assert_equal imported.id, synced.id
    assert_equal transactions_before, checking.entries.where(entryable_type: "Transaction").count
    imported.reload
    assert_equal [ "sfin-1", "simplefin", "Grocer" ], [ imported.external_id, imported.source, imported.name ]
    assert_equal "1", imported.transaction.extra.dig("monarch", "transaction_id")

    second = @family.imports.create!(type: "MonarchImport")
    second.attach_exports!(balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read)
    second.account_mappings.find_by!(key: "Checking").update!(mappable: checking)
    assert_equal 3, second.conversion.stats["transactions_skipped_already_in_sure"]
  end

  test "an existing account takes only one Monarch account" do
    account = @family.accounts.create!(name: "My Checking", balance: 0, currency: "USD", accountable: Depository.new)
    mapping("Checking").update!(mappable: account)

    error = assert_raises(ActiveRecord::RecordInvalid) { mapping("Card").update!(mappable: account) }
    assert_match "already the destination", error.message
  end

  test "a destination can move between Monarch accounts in one save" do
    account = @family.accounts.create!(name: "My Checking", balance: 0, currency: "USD", accountable: Depository.new)
    mapping("Checking").update!(mappable: account)

    @import.apply_account_choices!({
      mapping("Checking").id => { type: "Depository", include: "1", target_id: "" },
      mapping("Card").id => { type: "CreditCard", include: "1", target_id: account.id }
    }, target_accounts: @family.accounts)

    assert_equal [ nil, account ], [ mapping("Checking").target, mapping("Card").target ]
  end

  test "undo keeps an opening balance edited after the import" do
    account = @family.accounts.create!(name: "My Checking", balance: 500, currency: "USD", accountable: Depository.new)
    opening = account.entries.create!(date: Date.new(2024, 1, 3), amount: 500, currency: "USD", name: "Opening balance",
      entryable: Valuation.new(kind: "opening_anchor"))
    mapping("Checking").update!(mappable: account)
    publish!
    opening.reload.update!(amount: 123)

    @import.revert

    assert_equal 123, opening.reload.amount
    assert_equal [ "My Checking" ], @import.reload.opening_balances_kept_after_revert
  end

  test "existing categories and merchants are reused unchanged" do
    category = @family.categories.create!(name: "Groceries", color: "#123456", lucide_icon: "carrot", classification_unused: "expense")
    merchant = @family.merchants.create!(name: "Grocer", color: "#abcdef")
    publish!

    assert_equal [ "#123456", "carrot" ], [ category.reload.color, category.lucide_icon ]
    assert_equal "#abcdef", merchant.reload.color
    transaction = @family.entries.find_by!(name: "Grocer").entryable
    assert_equal [ category.id, merchant.id ], [ transaction.category_id, transaction.merchant_id ]
  end

  test "reverting removes the accounts it created" do
    publish!
    @import.revert

    assert_empty @family.accounts.reload
    assert @import.reload.pending?
  end

  private
    def mapping(name)
      @import.account_mappings.find_by!(key: name)
    end

    def publish!
      @import.reload.publish
      assert @import.reload.complete?, @import.error
    end

    def monarch_history
      MonarchImport::Exports.new(balances_csv: file_fixture("imports/monarch_balances.csv").read).balances
    end

    # Runs Sure's own balance calculation, then checks every day of the
    # Monarch history against what Sure stored.
    def assert_balances_match(history, account, sign)
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
      stored = account.balances.where(currency: account.currency).pluck(:date, :balance).to_h

      history.each do |date, balance|
        expected = balance * sign
        actual = stored.fetch(date) { stored.select { |day, _| day < date }.max_by(&:first)&.last }
        assert_equal expected, actual, "#{account.name} on #{date}"
      end
    end
end
