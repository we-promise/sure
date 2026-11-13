require "test_helper"

class SophtronAccountProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "credit override treats either provider sign as a credit" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_credit",
      balance: BigDecimal("-25"),
      balance_sign_override: "credit"
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    [ -25, 25 ].each do |observed|
      sophtron_account.update!(balance: observed)
      SophtronAccount::Processor.new(sophtron_account).process_account!

      assert_equal BigDecimal("-25"), acct.reload.balance
      assert_equal BigDecimal("-25"), acct.current_anchor_balance
    end
  end

  test "debt override treats either provider sign as debt" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_debt",
      balance: BigDecimal("-25"),
      balance_sign_override: "debt"
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    [ -25, 25 ].each do |observed|
      sophtron_account.update!(balance: observed)
      SophtronAccount::Processor.new(sophtron_account).process_account!

      assert_equal BigDecimal("25"), acct.reload.balance
    end
  end

  test "does not invert balance for asset accounts" do
    sophtron_account = create_sophtron_account(
      account_id: "dep_1",
      balance: BigDecimal("1000.00")
    )
    acct = link_account(accounts(:depository), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).process_account!

    assert_equal BigDecimal("1000.00"), acct.reload.balance
  end

  test "inverts negative balance for loan liabilities" do
    sophtron_account = create_sophtron_account(
      account_id: "loan_1",
      balance: BigDecimal("-400")
    )
    acct = link_account(accounts(:loan), sophtron_account)

    SophtronAccount::Processor.new(sophtron_account).process_account!

    assert_equal BigDecimal("400"), acct.reload.balance
  end

  test "automatic mode negates the balance and updates the anchor without scheduling a sync" do
    sophtron_account = create_sophtron_account(
      account_id: "cc_process",
      balance: BigDecimal("-50")
    )
    acct = link_account(accounts(:credit_card), sophtron_account)

    assert_no_difference -> { acct.syncs.count } do
      SophtronAccount::Processor.new(sophtron_account).process
    end

    assert_equal BigDecimal("50"), acct.reload.balance
    assert_equal BigDecimal("50"), acct.cash_balance
    assert_equal BigDecimal("50"), acct.current_anchor_balance
  end

  test "historical observations preserve current balance and cash balance" do
    sophtron_account = create_sophtron_account(account_id: "cc_future_anchor", balance: -25)
    acct = link_account(accounts(:credit_card), sophtron_account)
    acct.set_current_balance(100, date: Date.current + 1.day, schedule_sync: false)
    acct.update!(cash_balance: 100)

    SophtronAccount::Processor.new(sophtron_account).process

    assert_equal BigDecimal("100"), acct.reload.balance
    assert_equal BigDecimal("100"), acct.cash_balance
    assert_equal BigDecimal("100"), acct.current_anchor_balance
    historical_entry = acct.entries.valuations.find_by!(date: Date.current)
    assert_equal BigDecimal("25"), historical_entry.amount
    assert_equal "reconciliation", historical_entry.entryable.kind
  end

  private
    def create_sophtron_account(account_id:, balance:, balance_sign_override: nil)
      @item.sophtron_accounts.create!(
        account_id: account_id,
        name: account_id,
        currency: "USD",
        balance: balance,
        balance_sign_override: balance_sign_override
      )
    end

    def link_account(account, sophtron_account)
      AccountProvider.create!(account: account, provider: sophtron_account)
      account
    end
end
