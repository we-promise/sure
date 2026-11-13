require "test_helper"

class ApplyAllRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
    @transaction = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies all rules for a family, including inactive ones and locked fields" do
    rule = create_rule(active: false)
    @transaction.lock_attr!(:category_id)

    ApplyAllRulesJob.perform_now(@family)

    assert_equal @groceries_category, @transaction.reload.category
    assert_equal "manual", rule.rule_runs.last.execution_type
  end

  test "applies all rules with custom execution type" do
    rule = create_rule(active: true)

    ApplyAllRulesJob.perform_now(@family, execution_type: "scheduled")

    assert_equal "scheduled", rule.rule_runs.last.execution_type
  end

  test "does not email for an inactive rule" do
    rule = create_email_rule(active: false)

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      assert_no_enqueued_jobs only: RuleEmailNotificationJob do
        ApplyAllRulesJob.perform_now(@family)
      end
    end
  end

  test "applies an inactive rule's category action but does not email" do
    rule = create_email_rule(active: false, actions: [ category_action, email_action ])
    assert_nil @new_match.reload.category

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      assert_no_enqueued_jobs only: RuleEmailNotificationJob do
        ApplyAllRulesJob.perform_now(@family)
      end
    end

    assert_equal @groceries_category, @new_match.reload.category
  end

  test "emails new matches for an active rule" do
    rule = create_email_rule(active: true)

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      assert_enqueued_with(job: RuleEmailNotificationJob, args: [ rule.id, [ @new_match.id ] ]) do
        ApplyAllRulesJob.perform_now(@family)
      end
    end

    assert_enqueued_jobs 1, only: RuleEmailNotificationJob
  end

  test "does not re-send an active rule's already recorded matches" do
    rule = create_email_rule(active: true)
    NotificationDelivery.record_for(rule_id: rule.id, transaction_ids: [ @new_match.id ])

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      assert_no_enqueued_jobs only: RuleEmailNotificationJob do
        ApplyAllRulesJob.perform_now(@family)
      end
    end
  end

  private
    def category_action
      Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id)
    end

    def email_action
      Rule::Action.new(action_type: "send_email_notification")
    end

    # An email rule whose existing match is already recorded, as its baseline
    # leaves it, followed by one new match (@new_match) it has not seen.
    def create_email_rule(active:, actions: [ email_action ])
      rule = create_rule(active: active, actions: actions)
      NotificationDelivery.record_for(rule_id: rule.id, transaction_ids: [ @transaction.id ])
      @new_match = create_transaction(account: @account, name: "Whole Foods").transaction
      rule
    end

    def create_rule(active:, actions: [ category_action ])
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: active,
        effective_date: 1.day.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: actions
      )
    end
end
