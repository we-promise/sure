require "test_helper"
require "concurrent"

# Two syncs for the same account can overlap, and both then judge the same stale anchor.
#
# Real threads on real connections, so this needs real commits.
class Account::CurrentBalanceManagerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Anchor Race", currency: "USD")
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 1000, accountable: Depository.new)

    # Its own provider row: nothing is rolled back here, so claiming the shared fixture
    # would outlive the test.
    @plaid_account = PlaidAccount.create!(
      plaid_item: plaid_items(:one), currency: "USD", name: "Race Account",
      plaid_id: "acc_lock_test_#{SecureRandom.hex(4)}", plaid_type: "depository",
      current_balance: 1000, available_balance: 1000)
    @account.account_providers.create!(provider: @plaid_account)

    # Yesterday's reading, the row both writers race to judge.
    @stale_anchor = @account.entries.create!(
      date: Date.current - 1.day, name: "Current balance", amount: 1000, currency: "USD",
      entryable: Valuation.new(kind: "current_anchor"))
  end

  teardown do
    @account&.destroy
    @plaid_account&.destroy
    @family&.destroy
  end

  test "concurrent writers cannot both act on the same stale anchor" do
    latch = Concurrent::CountDownLatch.new(2)

    results = [ 600, 650 ].map do |balance|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Separate Account instances, as two sync jobs would have.
          manager = Account::CurrentBalanceManager.new(Account.find(@account.id))
          latch.count_down
          latch.wait(5)
          manager.set_current_balance(balance)
        end
      end
    end.map(&:value)

    assert results.all?(&:success?),
      "both writers should succeed, got errors: #{results.reject(&:success?).map(&:error)}"

    anchors = @account.valuations.current_anchor.includes(:entry)
    assert_equal 1, anchors.count, "the account must be left with exactly one current_anchor"
    assert_equal Date.current, anchors.first.entry.date
    assert_includes [ 600, 650 ], anchors.first.entry.amount.to_i,
      "the surviving anchor must hold one of the two reported readings"

    # What the lock prevents: the loser updates the row the winner already rotated, leaving
    # a waypoint dated today.
    waypoints = @account.valuations.where(kind: "reconciliation").includes(:entry)
    assert_empty waypoints.select { |v| v.entry.date == Date.current },
      "a preserved waypoint must never be dated today"
    assert_equal Date.current - 1.day, waypoints.first.entry.date
    assert_equal 1000, waypoints.first.entry.amount.to_i
  end
end
