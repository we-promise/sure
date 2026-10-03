require "test_helper"

class LunchflowAccountProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = LunchflowItem.new(family: @family, name: "Lunch Flow", api_key: "test_key")
    @item.save!(validate: false)
  end

  test "skips the account update when current_balance is nil (failed balance fetch)" do
    lf_acct = @item.lunchflow_accounts.create!(
      name: "Checking",
      account_id: "lf_1",
      currency: "USD",
      current_balance: nil
    )

    acct = accounts(:depository)
    acct.update!(balance: 500, cash_balance: 500, currency: "GBP")
    AccountProvider.create!(account: acct, provider: lf_acct)

    LunchflowAccount::Processor.new(lf_acct).send(:process_account!)

    acct.reload
    assert_equal BigDecimal("500"), acct.balance,
      "a sync whose balance fetch failed must not zero the account"
    assert_equal "GBP", acct.currency,
      "a sync whose balance fetch failed must not change the account currency"
  end

  test "still updates the account when current_balance is present" do
    lf_acct = @item.lunchflow_accounts.create!(
      name: "Checking",
      account_id: "lf_2",
      currency: "GBP",
      current_balance: BigDecimal("250")
    )

    acct = accounts(:depository)
    acct.update!(balance: 500, cash_balance: 500, currency: "GBP")
    AccountProvider.create!(account: acct, provider: lf_acct)

    LunchflowAccount::Processor.new(lf_acct).send(:process_account!)

    assert_equal BigDecimal("250"), acct.reload.balance
  end

  test "snapshot upsert preserves the existing currency when the payload omits it" do
    lf_acct = @item.lunchflow_accounts.create!(
      name: "Checking",
      account_id: "lf_3",
      currency: "GBP"
    )

    # The real accounts endpoint carries neither balance nor currency.
    lf_acct.upsert_lunchflow_snapshot!({ id: "lf_3", name: "Checking", status: "active" })

    lf_acct.reload
    assert_equal "GBP", lf_acct.currency,
      "an established account's currency must survive a currency-less snapshot"
    assert_nil lf_acct.current_balance
  end

  test "snapshot upsert falls back to USD when neither payload nor record has a valid currency" do
    lf_acct = @item.lunchflow_accounts.create!(
      name: "Checking",
      account_id: "lf_4",
      currency: "GBP"
    )
    # Simulate a record built from bad provider data (bypasses validation)
    lf_acct.update_column(:currency, "")

    lf_acct.upsert_lunchflow_snapshot!({ id: "lf_4", name: "Checking", status: "active" })

    assert_equal "USD", lf_acct.reload.currency,
      "a blank stored currency must fall through to USD, not fail validation"
  end

  test "negates credit card balances by default" do
    lf_acct, acct = create_linked_credit_card(current_balance: BigDecimal("-1715.18"))

    LunchflowAccount::Processor.new(lf_acct).send(:process_account!)

    assert_equal BigDecimal("1715.18"), acct.reload.balance
  end

  test "derives credit card debt from the card limit when the balance is available credit" do
    lf_acct, acct = create_linked_credit_card(current_balance: BigDecimal("4983.83"), available_credit: 5000)
    lf_acct.update!(treat_balance_as_available_credit: true)

    LunchflowAccount::Processor.new(lf_acct).send(:process_account!)

    acct.reload
    assert_equal BigDecimal("16.17"), acct.balance
    assert_equal BigDecimal("16.17"), acct.cash_balance
    assert_equal BigDecimal("5000"), acct.accountable.available_credit,
      "the user-entered limit must survive the sync"
  end

  test "keeps an overpaid card as a credit balance in available credit mode" do
    lf_acct, acct = create_linked_credit_card(current_balance: BigDecimal("5020"), available_credit: 5000)
    lf_acct.update!(treat_balance_as_available_credit: true)

    LunchflowAccount::Processor.new(lf_acct).send(:process_account!)

    assert_equal BigDecimal("-20"), acct.reload.balance
  end

  test "keeps the existing balance in available credit mode when no card limit is set" do
    lf_acct, acct = create_linked_credit_card(current_balance: BigDecimal("4983.83"), available_credit: nil)
    lf_acct.update!(treat_balance_as_available_credit: true)

    assert_difference -> { DebugLogEntry.where(provider_key: "lunchflow", account: acct).count }, 1 do
      LunchflowAccount::Processor.new(lf_acct).send(:process_account!)
    end

    assert_equal BigDecimal("300"), acct.reload.balance,
      "available credit must never be recorded as debt"
  end

  private
    def create_linked_credit_card(current_balance:, available_credit: nil)
      lf_acct = @item.lunchflow_accounts.create!(
        name: "Credit card",
        account_id: "lf_cc_#{SecureRandom.hex(4)}",
        currency: "GBP",
        current_balance: current_balance
      )

      acct = accounts(:credit_card)
      acct.update!(balance: 300, cash_balance: 300, currency: "GBP")
      acct.accountable.update!(available_credit: available_credit)
      AccountProvider.create!(account: acct, provider: lf_acct)

      [ lf_acct, acct ]
    end
end
