require "test_helper"

class Transaction::RefundDetailsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @date = Date.current - 2.days
  end

  test "a missing dated rate is resolved once across purchases in a batch" do
    purchases = 3.times.map { purchase_with_refund }
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: "USD", date: @date).once.returns(nil)
    details = Transaction::RefundDetails.new(transactions: purchases, user: @user)

    purchases.each do |purchase|
      result = details.for(purchase)
      assert_nil result[:net_purchase_cost]
      assert_equal "exchange_rate_missing", result[:net_purchase_cost_status]
    end
  end

  test "a successful dated rate is resolved once and preserves signed net costs" do
    purchases = [ purchase_with_refund, purchase_with_refund(refund_amount: -1000) ]
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: "USD", date: @date)
      .once.returns(OpenStruct.new(rate: BigDecimal("1.1")))
    details = Transaction::RefundDetails.new(transactions: purchases, user: @user)

    results = purchases.map { |purchase| details.for(purchase) }

    assert_equal [ "available", "available" ], results.map { |result| result[:net_purchase_cost_status] }
    assert_equal [ 12000, -10000 ], results.map { |result| result[:net_purchase_cost][:amount_cents] }
    assert_equal [ "120.0", "-100.0" ], results.map { |result| result[:net_purchase_cost][:amount] }
    assert_equal [ "USD", "USD" ], results.map { |result| result[:net_purchase_cost][:currency] }
  end

  test "rate cache distinguishes dates and both currencies" do
    purchases = [
      purchase_with_refund,
      purchase_with_refund(refund_date: @date - 1.day),
      purchase_with_refund(refund_currency: "GBP"),
      purchase_with_refund(purchase_currency: "GBP")
    ]
    [ [ "EUR", "USD", @date ], [ "EUR", "USD", @date - 1.day ],
      [ "GBP", "USD", @date ], [ "EUR", "GBP", @date ] ].each do |from, to, date|
      ExchangeRate.expects(:find_or_fetch_rate).with(from: from, to: to, date: date).once.returns(nil)
    end
    details = Transaction::RefundDetails.new(transactions: purchases, user: @user)

    purchases.each do |purchase|
      assert_equal "exchange_rate_missing", details.for(purchase)[:net_purchase_cost_status]
    end
  end

  test "a missing rate is retried by a new batch" do
    purchase = purchase_with_refund
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: "USD", date: @date)
      .once.returns(nil)
    first_batch = Transaction::RefundDetails.new(transactions: [ purchase ], user: @user)
    assert_equal "exchange_rate_missing", first_batch.for(purchase)[:net_purchase_cost_status]

    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: "USD", date: @date)
      .once.returns(OpenStruct.new(rate: BigDecimal("1.1")))
    second_batch = Transaction::RefundDetails.new(transactions: [ purchase ], user: @user)
    assert_equal 12000, second_batch.for(purchase)[:net_purchase_cost][:amount_cents]
  end

  test "same currency refunds do not resolve exchange rates" do
    purchase = purchase_with_refund(refund_currency: "USD")
    ExchangeRate.expects(:find_or_fetch_rate).never
    details = Transaction::RefundDetails.new(transactions: [ purchase ], user: @user)

    assert_equal 20000, details.for(purchase)[:net_purchase_cost][:amount_cents]
  end

  test "inaccessible refunds neither affect net cost nor resolve exchange rates" do
    purchase = purchase_with_refund(refund_currency: "USD")
    private_account = @user.family.accounts.create!(
      owner: users(:family_member), name: "Private account", currency: "GBP",
      balance: 1000, accountable: Depository.new
    )
    hidden_refund = create_transaction(account: private_account, amount: -100, currency: "GBP").transaction
    hidden_refund.mark_as_refund!(purchase: purchase)
    ExchangeRate.expects(:find_or_fetch_rate).never
    details = Transaction::RefundDetails.new(transactions: [ purchase ], user: @user)

    result = details.for(purchase)

    assert_equal 20000, result[:net_purchase_cost][:amount_cents]
    assert_not_includes result[:refund_transaction_ids], hidden_refund.id
    assert_equal "available", result[:net_purchase_cost_status]
  end

  private
    def purchase_with_refund(purchase_currency: "USD", refund_currency: "EUR", refund_amount: -800, refund_date: @date)
      purchase = create_transaction(amount: 1000, currency: purchase_currency).transaction
      refund = create_transaction(amount: refund_amount, currency: refund_currency, date: refund_date).transaction
      refund.mark_as_refund!(purchase: purchase)
      purchase
    end
end
