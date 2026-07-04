require "test_helper"

class EnableBankingAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "app_id",
      client_certificate: "cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_abc",
      currency: "EUR",
      current_balance: 1500.00
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
  end

  test "calls set_current_balance instead of direct account update" do
    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal 1500.0, @account.reload.cash_balance
  end

  test "updates account currency" do
    @enable_banking_account.update!(currency: "USD")

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal "USD", @account.reload.currency
  end

  test "does nothing when no linked account" do
    @account.account_providers.destroy_all

    result = EnableBankingAccount::Processor.new(@enable_banking_account).process
    assert_nil result
  end

  test "when treat_balance_as_available_credit is true, sets CC balance using limit and available credit" do
    cc_account = accounts(:credit_card)

    @enable_banking_account.update!(
      current_balance: 900.00,
      credit_limit: 1000.00,
      treat_balance_as_available_credit: true
    )
    relink_provider_to(cc_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal 100.0, cc_account.reload.cash_balance
    if cc_account.accountable.respond_to?(:available_credit)
      assert_equal 900.0, cc_account.accountable.reload.available_credit
    end
  end

  test "when treat_balance_as_available_credit is true and card is overpaid, floors debt at zero" do
    cc_account = accounts(:credit_card)

    @enable_banking_account.update!(
      current_balance: 1050.00, # overpaid by 50
      credit_limit: 1000.00,
      treat_balance_as_available_credit: true
    )
    relink_provider_to(cc_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal 0.0, cc_account.reload.cash_balance
    if cc_account.accountable.respond_to?(:available_credit)
      assert_equal 1050.0, cc_account.accountable.reload.available_credit
    end
  end

  test "when treat_balance_as_available_credit is true but limit absent, keeps existing balance" do
    cc_account = accounts(:credit_card)

    cc_account.accountable.update!(available_credit: 1000.0)

    @enable_banking_account.update!(
      current_balance: 900.00,
      credit_limit: nil,
      treat_balance_as_available_credit: true
    )

    relink_provider_to(cc_account)

    balance_before = cc_account.cash_balance

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    # The reported balance is available credit and there's no limit to reverse
    # from, so the debt is unknown. The existing balance must not be overwritten
    # with available credit, only the metadata is updated.
    assert_equal balance_before, cc_account.reload.cash_balance
    assert_equal 900.0, cc_account.accountable.reload.available_credit
  end

  test "when treat_balance_as_available_credit is false, treats balance as absolute debt natively" do
    cc_account = accounts(:credit_card)

    # API sends current_balance as debt (e.g. 100) and credit limit (e.g. 1000)
    # Debt should remain 100, available credit becomes 900
    @enable_banking_account.update!(
      current_balance: 100.00,
      credit_limit: 1000.00,
      treat_balance_as_available_credit: false
    )
    relink_provider_to(cc_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal 100.0, cc_account.reload.cash_balance
    if cc_account.accountable.respond_to?(:available_credit)
      assert_equal 900.0, cc_account.accountable.reload.available_credit
    end
  end

  test "sets CC balance to absolute debt when both limit and stored available_credit are absent" do
    cc_account = accounts(:credit_card)
    cc_account.accountable.update!(available_credit: nil)

    @enable_banking_account.update!(current_balance: 300.00, credit_limit: nil)

    relink_provider_to(cc_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    assert_equal 300.0, cc_account.reload.cash_balance
  end

  test "treat_balance_as_available_credit flag is a no-op on Loan accounts" do
    loan_account = accounts(:loan)

    # Even with the flag set to true, loans should only ever process as absolute debt
    @enable_banking_account.update!(
      current_balance: 50000.00,
      credit_limit: 100000.00,
      treat_balance_as_available_credit: true
    )

    relink_provider_to(loan_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process

    # Balance should match the absolute incoming balance, no credit limit math applied
    assert_equal 50000.0, loan_account.reload.cash_balance
  end

  private
    def relink_provider_to(account)
      AccountProvider.find_by(provider: @enable_banking_account)&.destroy
      AccountProvider.create!(account: account, provider: @enable_banking_account)
    end
end
