require "test_helper"

class SimplefinItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Importer Test",
      access_url: "https://example.com/access"
    )
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
  end

  test "normalizes numeric-string epoch balance-date for importer upserts" do
    epoch_string = Time.utc(2026, 6, 17, 12, 34, 56).to_i.to_s

    parsed = @importer.send(:normalize_balance_date, epoch_string)

    assert_equal Time.at(epoch_string.to_i).utc, parsed
  end

  test "balances-only import persists a negative provider credit-card debt as positive" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_amex_1", "Amex", "credit", -1911.72)
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Amex",
      balance: -1911.72,
      currency: "USD"
    })

    assert_equal 1911.72, credit_card.reload.balance
    assert_equal 1911.72, credit_card.cash_balance
  end

  test "balances-only import preserves a pinned currency and provider snapshot currency" do
    depository = accounts(:depository)
    simplefin_account = create_simplefin_account("sf_currency_pin", "Checking", "checking", 100)
    depository.update!(simplefin_account_id: simplefin_account.id, currency: "CAD")
    depository.lock_attr!(:currency)

    @importer.send(:import_account_minimal_and_balance, { id: simplefin_account.account_id, name: "Checking", balance: 100, currency: "USD" })

    assert_equal "CAD", depository.reload.currency
    assert_equal "USD", simplefin_account.reload.currency
  end

  test "balances-only import honors a pin on an AccountProvider-only link" do
    depository = accounts(:depository)
    simplefin_account = create_simplefin_account("sf_currency_pin_ap_only", "Checking", "checking", 100)
    depository.update!(currency: "CAD")
    AccountProvider.create!(account: depository, provider: simplefin_account)
    depository.lock_attr!(:currency)

    @importer.send(:import_account_minimal_and_balance, { id: simplefin_account.account_id, name: "Checking", balance: 100, currency: "USD" })

    assert_equal "CAD", depository.reload.currency
    assert_equal "USD", simplefin_account.reload.currency
  end

  test "balances-only import honors a credit balance sign override" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_credit_override_1", "Store Card", "credit", -48.48)
    simplefin_account.update!(balance_sign_override: "credit")
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Store Card",
      balance: -48.48,
      currency: "USD"
    })

    assert_equal(-48.48, credit_card.reload.balance)
    assert_equal(-48.48, credit_card.cash_balance)
  end

  test "balances-only import honors a debt balance sign override" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_debt_override_1", "Store Card", "credit", 48.48)
    simplefin_account.update!(balance_sign_override: "debt")
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Store Card",
      balance: 48.48,
      currency: "USD"
    })

    assert_equal 48.48, credit_card.reload.balance
    assert_equal 48.48, credit_card.cash_balance
  end

  test "balances-only import keeps a positive loan principal positive" do
    loan = accounts(:loan)
    simplefin_account = create_simplefin_account("sf_loan_1", "Mortgage Loan", "loan", 250_000)
    loan.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Mortgage Loan",
      balance: 250_000,
      currency: "USD"
    })

    assert_equal 250_000, loan.reload.balance
    assert_equal 250_000, loan.cash_balance
  end

  test "balances-only import keeps an explicit zero credit-card balance at zero" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_card_zero_1", "Paid Off Card", "credit", 0)
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Paid Off Card",
      balance: 0,
      "available-balance": 5_000,
      currency: "USD"
    })

    assert_equal 0, credit_card.reload.balance
    assert_equal 0, credit_card.cash_balance
  end

  test "balances-only import preserves a linked depository type over a liability inference" do
    depository = accounts(:depository)
    simplefin_account = create_simplefin_account("sf_linked_depository_1", "Mortgage Loan", "loan", 1_000)
    depository.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Mortgage Loan",
      type: "loan",
      balance: 1_000,
      currency: "USD"
    })

    assert_equal 1_000, depository.reload.balance
    assert_equal 1_000, depository.cash_balance
  end

  # Both steps read every provider's flag and decide "pending" the same way, so
  # the sync must count for review before it excludes: run through their one
  # caller and the stale Lunch Flow entry is reported and then excluded, rather
  # than excluded by the first step and invisible to the second. Swap the two
  # calls and stale_unmatched_pending goes to nil here.
  test "stale pending review counts every provider's flag before the exclusion hides it" do
    account = @family.accounts.create!(name: "Stale pending", balance: 0, currency: "USD", accountable: Depository.new)
    create_pending_entry(account, "simplefin_maybe", "simplefin", "maybe", 10)
    create_pending_entry(account, "simplefin_false", "simplefin", "off", 11)
    create_pending_entry(account, "lunchflow_pending", "lunchflow", true, 12)

    @importer.send(:review_and_exclude_stale_pending, account)

    stats = @importer.send(:stats)
    assert_equal 2, stats["stale_unmatched_pending"]
    assert_equal 2, stats["stale_pending_excluded"]
    assert_empty stats.fetch("reconciliation_errors", [])
    assert_equal [ "simplefin_false" ], account.entries.where(excluded: false).pluck(:name)
  end

  private

    def create_pending_entry(account, name, provider, pending, amount)
      account.entries.create!(
        name: name, date: 10.days.ago.to_date, amount: amount, currency: "USD",
        entryable: Transaction.new(extra: { provider => { "pending" => pending } })
      )
    end

    def create_simplefin_account(account_id, name, account_type, current_balance)
      @item.simplefin_accounts.create!(
        name: name,
        account_id: account_id,
        account_type: account_type,
        currency: "USD",
        current_balance: current_balance
      )
    end
end
