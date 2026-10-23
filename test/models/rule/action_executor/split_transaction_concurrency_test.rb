require "test_helper"
require "concurrent"

# Two split rules running against the same transaction at the same time must
# split it once, not twice. Real threads on real connections, so this needs
# real commits.
class Rule::ActionExecutor::SplitTransactionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Split Race", currency: "USD")
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new)
    @entry = Entry.create!(
      account: @account, name: "Bundle", date: Date.current,
      amount: 100, currency: "USD", entryable: Transaction.new)
    @rule = @family.rules.create!(
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
  end

  teardown do
    Entry.where(account_id: @account.id).where.not(parent_entry_id: nil).delete_all
    Entry.where(account_id: @account.id).delete_all
    Rule.where(family_id: @family.id).destroy_all
    @account.destroy
    @family.destroy
  end

  test "concurrent split rules split a transaction only once" do
    value = { splits: [
      { name: "Half A", share: "50", type: "fixed" },
      { name: "Half B", share: "50", type: "fixed" }
    ] }.to_json
    latch = Concurrent::CountDownLatch.new(2)

    2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          action = Rule::Action.new(rule: @rule, action_type: "split_transaction", value: value)
          scope = @account.transactions
          latch.count_down
          latch.wait(5)
          action.apply(scope)
        end
      end
    end.each(&:join)

    children = Entry.where(parent_entry_id: @entry.id)
    assert_equal 2, children.count, "the parent must be split exactly once"
    assert_equal 100, children.sum(:amount)
  end
end
