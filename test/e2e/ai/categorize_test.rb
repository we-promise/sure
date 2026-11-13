require "test_helper"

class AiE2eCategorizeTest < ActiveSupport::TestCase
  include AiE2eHelper, EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    @categories = [ "Coffee Shops", "Groceries", "Salary" ].map { @family.categories.create!(name: _1) }
    @transactions = [ [ "STARBUCKS 1234 SEATTLE", 4.5 ], [ "WHOLE FOODS MARKET #102", 86.2 ], [ "ACME CORP PAYROLL", -2500 ] ]
                      .map { |name, amount| create_transaction(account: @account, name:, amount:).transaction }
  end

  test "Kilo categorizes the family's transactions through the job" do
    with_live_ai { categorize }

    assert_categorized
    assert_ai_usage(@family, :categorize)
    assert_no_ai_errors
  end

  test "Jev categorizes the family's transactions through the job" do
    with_live_ai(jev: true) do
      assert Ai::Config.current.routes_for(:categorize).first.judge?, "categorize isn't routed to Jev"
      categorize
    end

    assert_categorized
    assert_no_ai_errors
  end

  test "a shadow run on Jev compares, and writes nothing to the transactions" do
    with_live_ai(jev: true, CATEGORIZATION_PROVIDER: "llm", CATEGORIZATION_SHADOW_RATE: "1") do
      perform_enqueued_jobs { categorize }
    end
    comparisons = Ai::Comparison.where(family: @family, feature: "categorize").index_by(&:subject_id)
    assert_equal @transactions.map(&:id).sort, comparisons.keys.sort
    # Each transaction holds the primary's answer (Kilo), whatever Jev said.
    @transactions.each do |transaction|
      assert_equal comparisons[transaction.id].primary_value.presence, transaction.reload.category_id
    end
    assert_ai_usage(@family, :categorize)
    assert_no_ai_errors
  end

  private
    def categorize
      Ai::GenerationJob.perform_now(:categorize, { ids: @transactions.map(&:id), family_id: @family.id })
    end

    # A model may abstain on an item; it may not answer outside the family's categories, and a
    # run where it answers nothing at all is broken plumbing, not a cautious model.
    def assert_categorized
      assigned = @transactions.map { _1.reload.category }
      assert assigned.compact.any?, "no transaction was categorized"
      assert (assigned.compact - @categories).empty?, "assigned a category outside the family's"
    end
end
