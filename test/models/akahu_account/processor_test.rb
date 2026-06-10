require "test_helper"

class AkahuAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = AkahuAccount.create!(
      akahu_item: @akahu_item,
      name: "Test Invest - Portfolio",
      account_id: "investment_123",
      currency: "NZD",
      current_balance: 12_345.67
    )
    @account = Account.create!(
      family: @family,
      name: "Portfolio",
      accountable: Investment.new,
      balance: 0,
      cash_balance: 999,
      currency: "NZD"
    )

    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "updates investment account balance without treating portfolio value as cash" do
    AkahuAccount::Processor.new(@akahu_account).process

    @account.reload
    assert_equal BigDecimal("12345.67"), @account.balance
    assert_equal BigDecimal("0"), @account.cash_balance
    assert_equal "NZD", @account.currency
  end

  test "logs account processing failures without raw exception message" do
    sensitive_message = "provider returned account holder details"
    error = RuntimeError.new(sensitive_message)

    @akahu_account.stubs(:current_account).returns(@account)
    @account.stubs(:update!).raises(error)
    scope = RecordingSentryScope.new
    Sentry.expects(:capture_exception).with do |captured_error|
      captured_error.is_a?(AkahuAccount::Processor::SanitizedProcessingError) &&
        !captured_error.equal?(error) &&
        captured_error.cause.nil? &&
        captured_error.message == "Akahu account processing failed" &&
        !captured_error.message.include?(sensitive_message)
    end.yields(scope).once
    Rails.logger.expects(:error).with do |message|
      message.include?("akahu_account_id=#{@akahu_account.id}") &&
        message.include?("error_class=RuntimeError") &&
        !message.include?(sensitive_message)
    end.once

    assert_raises(RuntimeError) do
      AkahuAccount::Processor.new(@akahu_account).process
    end

    assert_equal(
      {
        akahu_account_id: @akahu_account.id,
        context: "account",
        error_class: "RuntimeError"
      },
      scope.tags
    )
    assert_equal(
      {
        akahu_account_id: @akahu_account.id,
        context: "account",
        error_class: "RuntimeError"
      },
      scope.contexts["akahu_account_processor"]
    )
  end

  test "logs transaction processing failures without raw exception message" do
    sensitive_message = "provider returned account number 12-3456"
    error = RuntimeError.new(sensitive_message)

    AkahuAccount::Transactions::Processor.any_instance.stubs(:process).raises(error)
    scope = RecordingSentryScope.new
    Sentry.expects(:capture_exception).with do |captured_error|
      captured_error.is_a?(AkahuAccount::Processor::SanitizedProcessingError) &&
        !captured_error.equal?(error) &&
        captured_error.cause.nil? &&
        captured_error.message == "Akahu account processing failed" &&
        !captured_error.message.include?(sensitive_message)
    end.yields(scope).once
    Rails.logger.expects(:error).with do |message|
      message.include?("akahu_account_id=#{@akahu_account.id}") &&
        message.include?("error_class=RuntimeError") &&
        !message.include?(sensitive_message)
    end.once

    result = AkahuAccount::Processor.new(@akahu_account).process

    assert_equal false, result[:success]
    assert_equal(
      {
        akahu_account_id: @akahu_account.id,
        context: "transactions",
        error_class: "RuntimeError"
      },
      scope.tags
    )
    assert_equal(
      {
        akahu_account_id: @akahu_account.id,
        context: "transactions",
        error_class: "RuntimeError"
      },
      scope.contexts["akahu_account_processor"]
    )
  end

  class RecordingSentryScope
    attr_reader :tags, :contexts

    def initialize
      @tags = {}
      @contexts = {}
    end

    def set_tags(tags)
      @tags.merge!(tags)
    end

    def set_context(name, context)
      @contexts[name] = context
    end
  end
end
