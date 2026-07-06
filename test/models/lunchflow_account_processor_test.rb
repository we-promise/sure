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
end
