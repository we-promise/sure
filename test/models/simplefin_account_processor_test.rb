require "test_helper"

class SimplefinAccountProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN",
      access_url: "https://example.com/token"
    )
  end

  test "inverts negative balance for credit card liabilities" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Chase Credit",
      account_id: "cc_1",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("-123.45")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("123.45"), acct.reload.balance
  end

  test "does not invert balance for asset accounts (depository)" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "dep_1",
      currency: "USD",
      account_type: "checking",
      current_balance: BigDecimal("1000.00")
    )

    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("1000.00"), acct.reload.balance
  end

  test "inverts negative balance for loan liabilities" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Mortgage",
      account_id: "loan_1",
      currency: "USD",
      account_type: "mortgage",
      current_balance: BigDecimal("-50000")
    )

    acct = accounts(:loan)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("50000"), acct.reload.balance
  end
end
