require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::ProcessorTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @account = accounts(:crypto)
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.update!(cash_balance: 12, balance: 1012)
    @wallet = build_bitcoin_wallet(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    @account.holdings.create!(security: @wallet.security, date: Date.current, qty: "0.1", price: 10_000,
      amount: 1000, currency: "USD", cost_basis: 2000, cost_basis_source: "manual")
    @other = securities(:aapl)
    @other.prices.find_or_initialize_by(date: Date.current).update!(price: 100, currency: "USD")
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")
  end

  test "connecting replaces BTC once and preserves other holdings cash and basis" do
    @wallet.connect!
    assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: @wallet.security).qty
    assert_equal 1, @account.holdings.where(security: @wallet.security, date: Date.current).count
    assert_equal 2, @account.current_holdings.find_by!(security: @other).qty
    assert_equal 12, @account.reload.cash_balance
    assert_equal 2212, @account.balance
    assert_equal 2000, @account.current_holdings.find_by!(security: @wallet.security).cost_basis
    assert_empty @account.transactions
    assert @account.entries.where.not(entryable_type: "Valuation").all? { |entry| entry.amount.zero? }
  end

  test "repeated processing leaves one cash-neutral transfer" do
    @wallet.connect!
    @wallet.bitcoin_wallet_transactions.create!(txid: "b" * 64, amount_sats: 1000, occurred_at: Time.current)
    2.times { BitcoinWalletAccount::Processor.new(@wallet).process }
    entry = @account.entries.find_by!(source: "bitcoin_wallet")
    assert_equal 0, entry.amount
    assert_equal Trade::TRANSFER_LABEL, entry.entryable.investment_activity_label
    assert_equal BigDecimal("0.00001"), entry.entryable.qty
    assert_equal 1, @account.entries.where(source: "bitcoin_wallet").count
    assert_equal 12, @account.reload.cash_balance
  end

  test "disconnecting preserves the account positions and entries" do
    @wallet.connect!
    @wallet.disconnect!
    assert Account.exists?(@account.id)
    assert_equal BigDecimal("0.2"), @account.reload.current_holdings.find_by!(security: @wallet.security).qty
    refute @account.linked?
  end

  test "records before connection are not rewritten" do
    old = @account.holdings.create!(security: @wallet.security, date: 3.days.ago.to_date, qty: "0.1",
      price: 5000, amount: 500, currency: "USD")
    @wallet.connect!
    assert_equal BigDecimal("0.1"), old.reload.qty
    assert_equal 500, old.amount
  end

  test "later snapshots keep earlier Bitcoin holdings on their own dates" do
    @wallet.connect!
    first_date = Date.current
    travel 1.day do
      @wallet.update!(balance_sats: 30_000_000)
      BitcoinWalletAccount::Processor.new(@wallet).process
      assert_equal BigDecimal("0.2"), @account.holdings.find_by!(security: @wallet.security, date: first_date).qty
      assert_equal BigDecimal("0.3"), @account.holdings.find_by!(security: @wallet.security, date: Date.current).qty
    end
  end

  test "a source-set correction survives switching back to manual tracking" do
    @wallet.connect!
    @wallet.update!(balance_sats: 30_000_000)
    BitcoinWalletAccount::Processor.new(@wallet).process
    @wallet.disconnect!
    position = Holding::ForwardCalculator.new(@account, security_ids: [ @wallet.security_id ]).calculate.find { |row| row.date == Date.current }
    assert_equal BigDecimal("0.3"), position.qty
  end

  test "the Bitcoin provider does not prevent deleting an unrelated manual asset" do
    @wallet.connect!
    assert @account.can_delete_holding?(@account.holdings.find_by!(security: @other, date: Date.current))
    refute @account.can_delete_holding?(@account.holdings.find_by!(security: @wallet.security, date: Date.current))
  end

  test "future manual trades do not alter today's authoritative quantity" do
    @account.entries.create!(date: Date.current.next_day, amount: 0, currency: "USD", name: "Future transfer",
      entryable: Trade.new(security: @wallet.security, qty: "0.1", price: 10_000, currency: "USD", investment_activity_label: Trade::TRANSFER_LABEL))
    @wallet.connect!
    assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: @wallet.security).qty
    present_quantity = @account.trades.where(security: @wallet.security).joins(:entry).where("entries.date <= ?", Date.current).sum(:qty)
    assert_equal BigDecimal("0.2"), present_quantity
  end

  test "idle historical processing does not add read queries per day" do
    @wallet.connect!
    @wallet.update!(baseline_at: 2.days.ago)
    BitcoinWalletAccount::Processor.new(@wallet).process
    short = capture_sql_queries { BitcoinWalletAccount::Processor.new(@wallet).process }.count { |sql| sql.start_with?("SELECT") }
    @wallet.update!(baseline_at: 30.days.ago)
    BitcoinWalletAccount::Processor.new(@wallet).process
    long = capture_sql_queries { BitcoinWalletAccount::Processor.new(@wallet).process }.count { |sql| sql.start_with?("SELECT") }
    assert_operator long, :<=, short + 3
  end

  test "initial connection prepares a missing quote with today's date" do
    @wallet.security.prices.where(date: Date.current).delete_all
    @wallet.security.stubs(:price_data_provider).returns(:configured)
    imports = []
    # Model the provider's persisted quote and record the requested date range,
    # so the assertion covers valuation rather than only an import invocation.
    @wallet.security.define_singleton_method(:import_provider_prices) do |start_date:, end_date:|
      imports << { start_date: start_date, end_date: end_date }
      prices.create!(date: Date.current, price: 10_000, currency: "USD")
    end
    @wallet.connect!

    assert_equal [ { start_date: Date.current, end_date: Date.current } ], imports
    assert_equal BigDecimal("10_000"), @wallet.security.prices.find_by!(date: Date.current).price
    holding = @account.reload.current_holdings.find_by!(security: @wallet.security)
    assert_equal BigDecimal("0.2"), holding.qty
    assert_equal BigDecimal("10_000"), holding.price
    assert_equal BigDecimal("2000"), holding.amount
    assert_equal 2212, @account.balance
    assert_equal 12, @account.cash_balance
  end
end
