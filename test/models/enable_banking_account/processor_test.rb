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

  test "sets CC balance to available_credit when credit_limit is present" do
    cc_account = accounts(:credit_card)
    @enable_banking_account.update!(
      current_balance: 450.00,
      credit_limit: 1000.00
    )
    AccountProvider.find_by(provider: @enable_banking_account)&.destroy
    AccountProvider.create!(account: cc_account, provider: @enable_banking_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process
    
    assert_equal 550.0, cc_account.reload.cash_balance
    if cc_account.accountable.respond_to?(:available_credit)
      assert_equal 550.0, cc_account.accountable.reload.available_credit
    end
  end

  test "sets CC balance to raw outstanding when credit_limit is absent" do
    cc_account = accounts(:credit_card)
    @enable_banking_account.update!(current_balance: 300.00, credit_limit: nil)
    AccountProvider.find_by(provider: @enable_banking_account)&.destroy
    AccountProvider.create!(account: cc_account, provider: @enable_banking_account)

    EnableBankingAccount::Processor.new(@enable_banking_account).process
    
    assert_equal 300.0, cc_account.reload.cash_balance
  end
end
