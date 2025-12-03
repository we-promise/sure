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

  test "positive provider balance (overpayment) becomes negative for credit card liabilities" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Chase Credit",
      account_id: "cc_overpay",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("75.00") # provider sends positive for overpayment
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("-75.00"), acct.reload.balance
  end

  test "liability debt with both fields negative becomes positive (you owe)" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "BofA Visa",
      account_id: "cc_bofa_1",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("-1200"),
      available_balance: BigDecimal("-5000")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("1200"), acct.reload.balance
  end

  test "liability overpayment with both fields positive becomes negative (credit)" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "BofA Visa",
      account_id: "cc_bofa_2",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("75"),
      available_balance: BigDecimal("5000")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("-75"), acct.reload.balance
  end

  test "mixed signs falls back to invert observed (balance positive, avail negative => negative)" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Chase Freedom",
      account_id: "cc_chase_1",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("50"),
      available_balance: BigDecimal("-5000")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("-50"), acct.reload.balance
  end

  test "only available-balance present positive → negative (credit) for liability" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Chase Visa",
      account_id: "cc_chase_2",
      currency: "USD",
      account_type: "credit",
      current_balance: nil,
      available_balance: BigDecimal("25")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("-25"), acct.reload.balance
  end

  test "mislinked as asset but mapper infers credit → normalize as liability" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Visa Signature",
      account_id: "cc_mislinked",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("100.00"),
      available_balance: BigDecimal("5000.00")
    )

    # Link to an asset account intentionally
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    # Mapper should infer liability from name; final should be negative
    assert_equal BigDecimal("-100.00"), acct.reload.balance
  end
end
