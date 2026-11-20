require "test_helper"

class RulesRakeTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("rules:apply_all")
    Rake::Task["rules:apply_all"].reenable

    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @transaction = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies all rules in a single runner pass" do
    create_rule(category: @groceries)
    create_rule(category: @dining)

    Rule::Runner.expects(:new)
      .with(@family, has_entries(execution_type: "manual", ignore_attribute_locks: true))
      .once
      .returns(stub(run: [], errors: []))

    out, = capture_io { Rake::Task["rules:apply_all"].invoke(@family.id) }

    assert_match "Finished applying all rules", out
  end

  test "sets the category from the top rule" do
    create_rule(category: @groceries)
    create_rule(category: @dining)

    out, = capture_io { Rake::Task["rules:apply_all"].invoke(@family.id) }

    assert_equal @groceries, @transaction.reload.category
    assert_match "success", out
  end

  test "exits non-zero when a rule fails" do
    rule = create_rule(category: @groceries)
    Rule.any_instance.stubs(:apply).raises(StandardError, "boom")

    assert_raises(SystemExit) do
      capture_io { Rake::Task["rules:apply_all"].invoke(@family.id) }
    end

    assert_equal "failed", rule.rule_runs.last.status
  end

  test "reports a busy family lock instead of silently re-enqueueing" do
    create_rule(category: @groceries)
    Rule::Runner.any_instance.stubs(:with_family_lock).returns(false)

    assert_raises(SystemExit) do
      capture_io { Rake::Task["rules:apply_all"].invoke(@family.id) }
    end

    assert_no_enqueued_jobs
    assert_nil @transaction.reload.category
  end

  private
    def create_rule(category:)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        effective_date: 1.day.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
