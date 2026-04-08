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
    @enable_banking_account.stubs(:current_account).returns(@account)
    @account.expects(:set_current_balance).with(1500.0).once

    EnableBankingAccount::Processor.new(@enable_banking_account).process
  end

  test "updates account currency" do
    @enable_banking_account.update!(currency: "USD")
    @enable_banking_account.stubs(:current_account).returns(@account)
    @account.expects(:set_current_balance).returns(OpenStruct.new(success?: true))

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
    @enable_banking_account.stubs(:current_account).returns(cc_account)

    cc_account.expects(:set_current_balance).with(550.0).once

    EnableBankingAccount::Processor.new(@enable_banking_account).process
  end

  test "sets CC balance to raw outstanding when credit_limit is absent" do
    cc_account = accounts(:credit_card)
    @enable_banking_account.update!(current_balance: 300.00, credit_limit: nil)
    AccountProvider.find_by(provider: @enable_banking_account)&.destroy
    AccountProvider.create!(account: cc_account, provider: @enable_banking_account)
    @enable_banking_account.stubs(:current_account).returns(cc_account)

    # No credit_limit — balance stays as raw outstanding
    cc_account.expects(:set_current_balance).with(300.0).once

    EnableBankingAccount::Processor.new(@enable_banking_account).process
  end
end
