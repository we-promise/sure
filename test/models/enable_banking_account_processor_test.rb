require "test_helper"

class EnableBankingAccountProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = EnableBankingItem.new(family: @family, name: "Enable Banking",
      country_code: "GB", application_id: "test-app")
    @item.save!(validate: false)
  end

  test "skips the account update when current_balance is nil (failed balance fetch)" do
    eb_acct = @item.enable_banking_accounts.create!(
      name: "Checking",
      uid: "eb_1",
      currency: "GBP",
      current_balance: nil
    )

    acct = accounts(:depository)
    acct.update!(balance: 500, cash_balance: 500, currency: "GBP")
    AccountProvider.create!(account: acct, provider: eb_acct)

    EnableBankingAccount::Processor.new(eb_acct).send(:process_account!)

    acct.reload
    assert_equal BigDecimal("500"), acct.cash_balance,
      "a sync whose balance fetch failed must not zero the account"
    assert_equal BigDecimal("500"), acct.balance
    # Parity/invariant check, not regression coverage: unlike Lunch Flow, the
    # EB *processor* never had a currency-reset defect (its fallback chain
    # already preferred the stored value), so this assertion also passes on
    # main. The EB currency regression test lives at the model layer below.
    assert_equal "GBP", acct.currency,
      "a sync whose balance fetch failed must not change the account currency"
  end

  test "still updates the account when current_balance is present" do
    eb_acct = @item.enable_banking_accounts.create!(
      name: "Checking",
      uid: "eb_2",
      currency: "GBP",
      current_balance: BigDecimal("250")
    )

    acct = accounts(:depository)
    acct.update!(balance: 500, cash_balance: 500, currency: "GBP")
    AccountProvider.create!(account: acct, provider: eb_acct)

    EnableBankingAccount::Processor.new(eb_acct).send(:process_account!)

    assert_equal BigDecimal("250"), acct.reload.cash_balance
  end
  test "snapshot upsert preserves an established currency when the payload omits it" do
    eb_acct = @item.enable_banking_accounts.create!(name: "Checking", uid: "eb_3", currency: "GBP")

    eb_acct.upsert_enable_banking_snapshot!({ uid: "eb_3", name: "Checking" })

    assert_equal "GBP", eb_acct.reload.currency,
      "an omitted payload currency must not reset an established account to EUR"
  end
end
