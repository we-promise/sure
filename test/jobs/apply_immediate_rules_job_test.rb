require "test_helper"

class ApplyImmediateRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Immediate test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @changed = create_transaction(account: @account, name: "Whole Foods").transaction
    @untouched = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies immediate rules only to the given transactions" do
    rule = create_rule("Groceries", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal @groceries, @changed.reload.category
    assert_nil @untouched.reload.category
    assert_equal [ "immediate" ], rule.rule_runs.pluck(:execution_type)
  end

  test "leaves nightly-only and inactive rules alone" do
    nightly = create_rule("Nightly", category: @groceries)
    inactive = create_rule("Inactive", category: @groceries, apply_immediately: true, active: false)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_nil @changed.reload.category
    assert_empty nightly.rule_runs
    assert_empty inactive.rule_runs
  end

  test "active rules above run first on the same transactions and win their fields" do
    nightly = create_rule("Nightly", category: @dining)
    create_rule("Immediate", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal @dining, @changed.reload.category
    assert_nil @untouched.reload.category
    assert_equal [ "immediate" ], nightly.rule_runs.pluck(:execution_type)
  end

  test "an immediate rule sees a rename made by a rule above" do
    create_rule("Rename", action: Rule::Action.new(action_type: "set_transaction_name", value: "WF Market"))
    create_rule("Immediate", match: "WF Market", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal "WF Market", @changed.reload.entry.name
    assert_equal @groceries, @changed.category
    assert_equal "Whole Foods", @untouched.reload.entry.name
  end

  test "rules below the last immediate rule wait for the nightly run" do
    create_rule("Immediate", action: Rule::Action.new(action_type: "set_transaction_name", value: "WF Market"), apply_immediately: true)
    below = create_rule("Below", category: @groceries)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_nil @changed.reload.category
    assert_empty below.rule_runs
  end

  test "keeps fields the person set themselves" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)
    @changed.update!(category: @dining)
    @changed.lock_attr!(:category_id)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal @dining, @changed.reload.category
  end

  test "records no run for rules that match none of the transactions" do
    rule = create_rule("Other", match: "Hardware", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_empty rule.rule_runs
  end

  test "offers a refresh toast only when a rule changed something" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)

    # A full-page refresh would wipe forms that are still open (the drawer the
    # person just edited in, or another family member's), so only the toast is sent.
    Family.any_instance.expects(:broadcast_refresh).never
    Family.any_instance.expects(:broadcast_replace_to)
      .with(@family, target: "sync-toast", partial: "shared/notifications/sync_toast").once
    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    Family.any_instance.expects(:broadcast_replace_to).never
    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
  end

  test "leaves the emails of rules above to the nightly run" do
    email = create_rule("Email", action: Rule::Action.new(action_type: "send_email_notification"))
    create_rule("Immediate", category: @groceries, apply_immediately: true)

    assert_no_enqueued_jobs(only: RuleEmailNotificationJob) do
      ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
    end

    assert_equal @groceries, @changed.reload.category
    assert_empty NotificationDelivery.where(rule_id: email.id)
    assert_empty email.rule_runs
  end

  test "a rule above that only emails still stops the rules below" do
    email = create_rule("Email", action: Rule::Action.new(action_type: "send_email_notification"))
    email.update!(stop_processing: true)
    create_rule("Immediate", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_nil @changed.reload.category
  end

  test "an immediate rule sends its own email right away" do
    email = create_rule("Email", action: Rule::Action.new(action_type: "send_email_notification"), apply_immediately: true)

    assert_enqueued_with(job: RuleEmailNotificationJob, args: [ email.id, [ @changed.id ] ]) do
      ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
    end
  end

  test "retries later when another rule run holds the family lock" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)
    Rule::Runner.any_instance.stubs(:run).raises(Rule::Runner::LockBusy)

    assert_enqueued_with(job: ApplyImmediateRulesJob) do
      ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
    end
  end

  private
    def create_rule(name, category: nil, match: "Whole Foods", apply_immediately: false, active: true, action: nil)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: active,
        apply_immediately: apply_immediately,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
        actions: [ action || Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
