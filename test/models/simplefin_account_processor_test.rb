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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process

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

    SimplefinAccount::Processor.new(sfin_acct).process
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
      SimplefinAccount::Processor.new(sfin_acct).process
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
      SimplefinAccount::Processor.new(sfin_acct).process
    end
    original = acct.reload.valuations.current_anchor.first
    assert original

    sfin_acct.update!(currency: "EUR", current_balance: BigDecimal("1800"))
    Account::CurrentBalanceManager.any_instance.stubs(:create_current_anchor).raises(ActiveRecord::StatementInvalid, "boom")

    assert_no_difference -> { acct.valuations.count } do
      SimplefinAccount::Processor.new(sfin_acct.reload).process
    end

    acct.reload
    assert_equal "current_anchor", Valuation.find(original.id).kind
    assert_equal BigDecimal("1500"), acct.balance
    assert_equal BigDecimal("1500"), acct.cash_balance
    assert_equal "USD", acct.currency
  end

  test "a failed balance write keeps the imported transactions and the previous balance" do
    sfin_acct, acct = link_checking("chk_failed_after_import", balance: "1475")
    sfin_acct.update!(raw_transactions_payload: [ coffee_payload("TRN-failed-write-1") ])

    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )

    assert_difference -> { acct.entries.transactions.count }, 1 do
      SimplefinAccount::Processor.new(sfin_acct.reload).process
    end

    acct.reload
    assert_equal BigDecimal("1000"), acct.balance
    assert_equal BigDecimal("1000"), acct.cash_balance
    assert_empty acct.valuations
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

  # Account::CurrentBalanceManager judges the previous anchor against the
  # entries already on the account, so the anchor is written after this
  # sync's transactions are imported.
  test "an anchor the imported transactions explain moves forward" do
    Rails.configuration.x.balance.stubs(:reuse_explained_anchor).returns(true)
    sfin_acct, acct = link_checking("chk_explained", balance: "1500")

    travel_to 1.day.ago do
      SimplefinAccount::Processor.new(sfin_acct).process
    end
    anchor = acct.reload.valuations.current_anchor.sole

    sfin_acct.update!(
      current_balance: BigDecimal("1475"),
      raw_transactions_payload: [ coffee_payload("TRN-explained-1") ]
    )
    SimplefinAccount::Processor.new(sfin_acct.reload).process

    acct.reload
    assert_equal 1, acct.entries.transactions.count
    assert_empty acct.valuations.reconciliation
    assert_equal anchor, acct.valuations.current_anchor.sole
    assert_equal Date.current, anchor.entry.reload.date
    assert_equal BigDecimal("1475"), anchor.entry.amount
    assert_equal BigDecimal("1475"), acct.balance
  end

  # A second sync on the same day that reports a new currency reuses the
  # day's anchor. The anchor and the transactions imported before it is written
  # both follow the snapshot's currency.
  test "a same-day sync in a new currency relabels the anchor and its transactions" do
    sfin_acct, acct = link_checking("chk_currency_change", balance: "1500")
    SimplefinAccount::Processor.new(sfin_acct).process
    anchor = acct.reload.valuations.current_anchor.sole
    assert_equal "USD", anchor.entry.currency

    sfin_acct.update!(
      currency: "EUR",
      current_balance: BigDecimal("1300"),
      raw_transactions_payload: [ coffee_payload("TRN-currency-change") ]
    )
    SimplefinAccount::Processor.new(sfin_acct.reload).process

    acct.reload
    assert_equal "EUR", acct.currency
    assert_equal anchor, acct.valuations.current_anchor.sole
    assert_equal "EUR", anchor.entry.reload.currency
    assert_equal BigDecimal("1300"), anchor.entry.amount
    assert_equal [ "EUR" ], acct.entries.transactions.pluck(:currency)
  end

  test "a transaction that fails to import keeps the previous anchor as a waypoint" do
    Rails.configuration.x.balance.stubs(:reuse_explained_anchor).returns(true)
    sfin_acct, acct = link_checking("chk_partial_import", balance: "1500")

    travel_to 1.day.ago do
      SimplefinAccount::Processor.new(sfin_acct).process
    end

    # The account already holds an entry that explains the move, but this
    # sync's import leaves a row out, so the ledger is not trusted.
    acct.entries.create!(date: Date.current, name: "Coffee", amount: 25, currency: "USD", entryable: Transaction.new)
    sfin_acct.update!(
      current_balance: BigDecimal("1475"),
      raw_transactions_payload: [ coffee_payload("TRN-partial-1") ]
    )
    SimplefinEntry::Processor.any_instance.stubs(:process).raises(StandardError, "boom")

    SimplefinAccount::Processor.new(sfin_acct.reload).process

    acct.reload
    assert_equal BigDecimal("1475"), acct.balance
    anchor = acct.valuations.current_anchor.sole.entry
    assert_equal Date.current, anchor.date
    assert_equal BigDecimal("1475"), anchor.amount

    preserved = acct.valuations.reconciliation.sole.entry
    assert_equal Date.current - 1.day, preserved.date
    assert_equal BigDecimal("1500"), preserved.amount
  end

  private
    # A checking account with no entries of its own, so the ledger the
    # balance manager reads holds only what each test adds.
    def link_checking(account_id, balance:)
      sfin_acct = SimplefinAccount.create!(
        simplefin_item: @item,
        name: "Checking",
        account_id: account_id,
        currency: "USD",
        account_type: "checking",
        current_balance: BigDecimal(balance)
      )
      acct = @family.accounts.create!(
        name: "Checking",
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        accountable: Depository.new,
        simplefin_account: sfin_acct
      )

      [ sfin_acct, acct ]
    end

    def coffee_payload(id)
      {
        "id" => id,
        "posted" => Time.current.to_i,
        "amount" => "-25.00",
        "description" => "Coffee",
        "payee" => "Coffee",
        "transacted_at" => Time.current.to_i
      }
    end
end
