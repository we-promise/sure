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

  test "keeps a user-pinned currency while preserving the provider currency" do
    sfin_acct = SimplefinAccount.create!(simplefin_item: @item, name: "Checking", account_id: "currency_pin", currency: "USD", account_type: "checking", current_balance: BigDecimal("100"))
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct, currency: "CAD")
    acct.lock_attr!(:currency)
    sfin_acct.update!(currency: "USD", raw_payload: { currency: "USD" })

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal "USD", sfin_acct.reload.currency
    assert_equal "USD", sfin_acct.raw_payload.with_indifferent_access[:currency]
    assert_equal "CAD", acct.reload.currency
  end

  test "an unlocked account follows the provider currency" do
    sfin_acct = SimplefinAccount.create!(simplefin_item: @item, name: "Checking", account_id: "currency_follow", currency: "CAD", account_type: "checking", current_balance: BigDecimal("100"))
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct, currency: "USD")

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal "CAD", acct.reload.currency
  end

  test "pinning the current currency still prevents later provider changes" do
    sfin_acct = SimplefinAccount.create!(simplefin_item: @item, name: "Checking", account_id: "currency_equal_pin", currency: "CAD", account_type: "checking", current_balance: BigDecimal("100"))
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct, currency: "USD")
    acct.lock_attr!(:currency)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal "USD", acct.reload.currency
  end

  test "AccountProvider-only link honors a pinned currency in full processing" do
    sfin_acct = SimplefinAccount.create!(simplefin_item: @item, name: "Checking", account_id: "currency_pin_ap_only", currency: "USD", account_type: "checking", current_balance: BigDecimal("100"))
    acct = accounts(:depository)
    acct.update!(currency: "CAD")
    AccountProvider.create!(account: acct, provider: sfin_acct)
    acct.lock_attr!(:currency)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal "CAD", acct.reload.currency
    assert_equal "USD", sfin_acct.reload.currency
  end

  test "unlocking currency allows the provider currency to apply again" do
    sfin_acct = SimplefinAccount.create!(simplefin_item: @item, name: "Checking", account_id: "currency_reset", currency: "CAD", account_type: "checking", current_balance: BigDecimal("100"))
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct, currency: "USD")
    acct.lock_attr!(:currency)
    acct.unlock_attr!(:currency)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal "CAD", acct.reload.currency
    refute acct.locked?(:currency)
  end

  test "credit override preserves an ambiguous provider balance as a credit" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Credit balance",
      account_id: "cc_credit_override",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("-25"),
      available_balance: BigDecimal("0"),
      balance_sign_override: "credit"
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("-25"), acct.reload.balance
  end

  test "debt override preserves an ambiguous provider balance as debt" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Debt balance",
      account_id: "cc_debt_override",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("-25"),
      available_balance: BigDecimal("0"),
      balance_sign_override: "debt"
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    assert_equal BigDecimal("25"), acct.reload.balance
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

  # Many banks (and most mortgage feeds) report the loan principal
  # outstanding as a positive number from the bank's books. The old
  # liability path ran every Loan through OverpaymentAnalyzer +
  # normalize_liability_balance, and the latter's fallback for
  # `:unknown` classifications returned `-observed`, flipping a
  # bank-reported `+50000` into `-50000`. That bug made loans _add_ to
  # net worth instead of subtracting, so this test pins the corrected
  # behaviour.
  test "preserves positive provider balance for loan liabilities" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Mortgage",
      account_id: "loan_2",
      currency: "USD",
      account_type: "mortgage",
      current_balance: BigDecimal("50000")
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

  test "linked depository account type takes precedence over mapper-inferred liability" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Visa Signature",
      account_id: "cc_mislinked_asset",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("100.00"),
      available_balance: BigDecimal("5000.00")
    )

    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    # Manual selection as depository; final should be the same
    assert_equal BigDecimal("100.00"), acct.reload.balance
  end

  test "linked credit card account type takes precedence over mapper-inferred liability" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Visa Signature",
      account_id: "cc_mislinked_liability",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("100.00"),
      available_balance: BigDecimal("5000.00")
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    # Liability has flipped sign; final should be negative
    assert_equal BigDecimal("-100.00"), acct.reload.balance
  end

  test "dormant credit card with zero balance and negative available-balance shows zero debt" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Discover Card",
      account_id: "cc_dormant",
      currency: "USD",
      account_type: "credit",
      current_balance: BigDecimal("0"),
      available_balance: BigDecimal("-3800") # credit limit reported as negative
    )

    acct = accounts(:credit_card)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    # Should use explicit zero balance, not negative available_balance
    assert_equal BigDecimal("0"), acct.reload.balance
  end
end
