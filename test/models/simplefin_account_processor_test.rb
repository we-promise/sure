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

  test "records the reported balance as the current anchor" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_anchor",
      currency: "USD",
      account_type: "checking",
      current_balance: BigDecimal("1500")
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)

    acct.reload
    anchor = acct.valuations.current_anchor.first&.entry
    assert anchor, "expected a current_anchor valuation"
    assert_equal Date.current, anchor.date
    assert_equal BigDecimal("1500"), anchor.amount
    assert_equal BigDecimal("1500"), acct.balance
    assert_equal BigDecimal("1500"), acct.cash_balance
  end

  test "does not queue an account sync when setting the balance" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_no_sync",
      currency: "USD",
      account_type: "checking",
      current_balance: BigDecimal("1500")
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    Account.any_instance.expects(:sync_later).never

    SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)
  end

  test "a failed balance write changes nothing and is logged against the connection" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_failed_write",
      currency: "EUR",
      account_type: "checking",
      current_balance: BigDecimal("1500")
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)
    provider = AccountProvider.create!(account: acct, provider: sfin_acct)
    original = acct.reload.slice(:balance, :cash_balance, :currency)

    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )

    sfin_acct.reload
    assert_difference -> { DebugLogEntry.count }, 1 do
      SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)
    end

    # The processor's own account object drops the rolled-back currency too.
    assert_equal original, sfin_acct.current_account.slice(:balance, :cash_balance, :currency)
    assert_equal original, acct.reload.slice(:balance, :cash_balance, :currency)

    log = DebugLogEntry.order(:created_at).last
    assert_equal "simplefin", log.provider_key
    assert_equal acct, log.account
    assert_equal provider, log.account_provider
  end

  # The manager's lock joins the processor's transaction, so a write that fails
  # after the previous anchor was rotated must roll back the rotation and the
  # currency with it, or the account is left with no current anchor.
  test "a write that fails part-way leaves the previous anchor as it was" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_partial_write",
      currency: "USD",
      account_type: "checking",
      current_balance: BigDecimal("1500")
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    travel_to 1.day.ago do
      SimplefinAccount::Processor.new(sfin_acct).send(:process_account!)
    end
    original = acct.reload.valuations.current_anchor.first
    assert original

    sfin_acct.update!(currency: "EUR", current_balance: BigDecimal("1800"))
    Account::CurrentBalanceManager.any_instance.stubs(:create_current_anchor).raises(ActiveRecord::StatementInvalid, "boom")

    assert_no_difference -> { acct.valuations.count } do
      SimplefinAccount::Processor.new(sfin_acct.reload).send(:process_account!)
    end

    acct.reload
    assert_equal "current_anchor", Valuation.find(original.id).kind
    assert_equal BigDecimal("1500"), acct.balance
    assert_equal BigDecimal("1500"), acct.cash_balance
    assert_equal "USD", acct.currency
  end

  test "a failed balance write stops the rest of that account's processing" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_halt",
      currency: "USD",
      account_type: "checking",
      current_balance: BigDecimal("1500"),
      raw_transactions_payload: [
        {
          "id" => "TRN-halt-1",
          "posted" => 1.day.ago.to_i,
          "amount" => "-25.00",
          "description" => "Coffee",
          "payee" => "Coffee",
          "transacted_at" => 1.day.ago.to_i
        }
      ]
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct)

    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )
    SimplefinAccount::Processor.any_instance.expects(:process_transactions).never
    SimplefinAccount::Processor.any_instance.expects(:process_investments).never
    SimplefinAccount::Processor.any_instance.expects(:process_liabilities).never

    assert_no_difference -> { acct.entries.count } do
      SimplefinAccount::Processor.new(sfin_acct.reload).process
    end
  end

  test "a failed balance write inside a caller's transaction rolls back only its own writes" do
    sfin_acct = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Checking",
      account_id: "chk_savepoint",
      currency: "EUR",
      account_type: "checking",
      current_balance: BigDecimal("1500")
    )
    acct = accounts(:depository)
    acct.update!(simplefin_account: sfin_acct, currency: "USD")

    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )

    Account.transaction do
      @item.update!(name: "Before")
      SimplefinAccount::Processor.new(sfin_acct.reload).process
      @family.update!(name: "After")
    end

    assert_equal "Before", @item.reload.name
    assert_equal "After", @family.reload.name
    assert_equal "USD", acct.reload.currency
  end
end
