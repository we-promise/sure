require "test_helper"

class AkahuAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @account = AkahuAccount.create!(
      akahu_item: @item,
      name: "Test Account",
      account_id: "acc_123",
      currency: "NZD"
    )
  end

  test "maps common Akahu account types to Sure accountable types" do
    @account.update!(account_type: "CHECKING")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype

    @account.update!(account_type: "SAVINGS")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype

    @account.update!(account_type: "TERMDEPOSIT")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "cd", @account.suggested_subtype

    @account.update!(account_type: "CREDITCARD")
    assert_equal "CreditCard", @account.suggested_account_type
    assert_equal "credit_card", @account.suggested_subtype
  end

  test "maps KIWISAVER and INVESTMENT to Investment" do
    @account.update!(account_type: "KIWISAVER")
    assert_equal "Investment", @account.suggested_account_type
    assert_equal "retirement", @account.suggested_subtype

    @account.update!(account_type: "INVESTMENT")
    assert_equal "Investment", @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "returns skip when Akahu account type is unmapped" do
    @account.update!(account_type: "WALLET")
    assert_nil @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "is case insensitive for mapping" do
    @account.update!(account_type: "savings")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype
  end

  test "transaction processor hides raw exception messages from result errors" do
    raw_message = "raw provider payload with sensitive-value"
    AkahuAccount::Transactions::Processor.any_instance
      .stubs(:process)
      .raises(StandardError.new(raw_message))

    AccountProvider.create!(account: accounts(:investment), provider: @account)
    result = @item.process_accounts.first

    assert_equal false, result[:success]
    assert_equal I18n.t("akahu_item.errors.account_processing_failed"), result[:error]
    refute_includes result.inspect, raw_message
  end

  test "process accounts sanitizes failed processor result payload" do
    raw_message = "raw provider failure with account number 12-3456"
    AkahuAccount::Processor.any_instance.stubs(:process).returns(
      success: false,
      error: raw_message,
      result: {
        success: false,
        total: 1,
        imported: 0,
        failed: 1,
        pruned_pending: 0,
        errors: []
      },
      errors: [ { error: raw_message } ]
    )

    AccountProvider.create!(account: accounts(:investment), provider: @account)
    result = @item.process_accounts.first

    assert_equal @account.id, result[:akahu_account_id]
    assert_equal false, result[:success]
    assert_equal I18n.t("akahu_item.errors.account_processing_failed"), result[:error]
    refute result.key?(:result)
    refute result.key?(:errors)
    refute_includes result.inspect, raw_message
  end
end
