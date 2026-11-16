require "test_helper"

class Rule::ActionExecutor::AutoDetectMerchantsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @rule = @family.rules.create!(
      name: "AI merchant rule",
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      actions: [ Rule::Action.new(action_type: "auto_detect_merchants") ]
    )
    @executor = Rule::ActionExecutor::AutoDetectMerchants.new(@rule)
  end

  test "queues one job per LLM call, sized by LLM_MAX_ITEMS_PER_CALL" do
    5.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    Family.any_instance.expects(:auto_detect_transaction_merchants_later).times(3)

    with_env_overrides("LLM_MAX_ITEMS_PER_CALL" => "2") do
      assert_equal 3, @executor.execute(@account.transactions)[:jobs_count]
    end
  end
end
