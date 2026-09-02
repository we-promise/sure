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

  private

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
