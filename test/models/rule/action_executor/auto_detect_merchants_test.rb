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

  test "queues one job per LLM call, sized by the route model's batch size" do
    5.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    Family.any_instance.expects(:auto_detect_transaction_merchants_later).times(3)

    with_ai_model_settings(batch_size: 2) do
      assert_equal 3, @executor.execute(@account.transactions)[:jobs_count]
    end
  end
end
