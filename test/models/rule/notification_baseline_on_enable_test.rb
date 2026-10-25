require "test_helper"

# A rule with an email action records its current matches as already delivered
# when it is switched on, so turning a rule back on emails only what appears
# afterwards. Rule::Action seeds the same baseline when the action is created,
# but that does not cover a rule that was switched off and on again: the matches
# from before (or while it was off) would all be emailed on its next run.
#
# Every rule built here starts without a baseline, which is the state this guards
# against: email_rule deletes any baseline the action recorded when it was created,
# so these tests hold whether or not creating the action seeds one.
class Rule::NotificationBaselineOnEnableTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Baseline", balance: 1000, currency: "USD", accountable: Depository.new)
    @hit = create_transaction(date: Date.current, account: @account, name: "AMZN Mktp US").transaction
    @miss = create_transaction(date: Date.current, account: @account, name: "Corner shop").transaction
  end

  test "switching on a rule with an email action records its matches without emailing them" do
    rule = email_rule

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      assert_no_enqueued_jobs(only: RuleEmailNotificationJob) { rule.update!(active: true) }
    end
    assert_equal [ @hit.id ], NotificationDelivery.where(rule: rule).pluck(:transaction_id)

    assert_no_enqueued_jobs(only: RuleEmailNotificationJob) { rule.apply }
  end

  test "a match that appears after the rule is switched on is still emailed" do
    rule = email_rule
    rule.update!(active: true)
    later = create_transaction(date: Date.current, account: @account, name: "AMZN Prime").transaction

    assert_enqueued_with(job: RuleEmailNotificationJob, args: [ rule.id, [ later.id ] ]) { rule.apply }
  end

  test "the baseline is taken from the conditions saved in the same form submit" do
    rule = email_rule
    condition = rule.conditions.first

    rule.update!(active: true, conditions_attributes: [ { id: condition.id, value: "corner" } ])

    assert_equal [ @miss.id ], NotificationDelivery.where(rule: rule).pluck(:transaction_id)
  end

  test "a condition removed in the same form submit does not narrow the baseline" do
    rule = email_rule
    rule.conditions.create!(condition_type: "transaction_name", operator: "like", value: "nothing matches this")

    rule.update!(active: true, conditions_attributes: [ { id: rule.conditions.last.id, _destroy: "1" } ])

    assert_equal [ @hit.id ], NotificationDelivery.where(rule: rule).pluck(:transaction_id)
  end

  test "switching on a rule without an email action records nothing" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction",
      conditions: [ name_condition("amzn") ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )
    Rule.any_instance.expects(:matching_transaction_ids).never

    assert_no_difference -> { NotificationDelivery.count } do
      rule.update!(active: true)
    end
    assert rule.reload.active?
  end

  test "saving a rule that is already on does not record a baseline again" do
    rule = email_rule
    rule.update_columns(active: true)

    assert_no_difference -> { NotificationDelivery.count } do
      rule.update!(name: "Renamed")
    end
  end

  test "switching a rule off records nothing" do
    rule = email_rule
    rule.update_columns(active: true)

    assert_no_difference -> { NotificationDelivery.count } do
      rule.update!(active: false)
    end
  end

  test "a baseline that times out on switch-on leaves the rule off and the rest of the save in place" do
    rule = email_rule(condition: Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "amzn"))
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_difference -> { DebugLogEntry.where(category: "rule_notification").count }, 1 do
      assert_nothing_raised { rule.update!(active: true, name: "Renamed") }
    end

    assert rule.notification_baseline_timed_out?
    entry = DebugLogEntry.where(category: "rule_notification").last
    assert_equal "warn", entry.level
    assert_equal @family, entry.family
    assert_equal rule.id, entry.metadata["rule_id"]
    rule.reload
    assert_not rule.active?, "a rule without a baseline would email every past match"
    assert_equal "Renamed", rule.name
    assert_equal 0, NotificationDelivery.where(rule: rule).count
  end

  test "a baseline that is recorded does not report a timeout" do
    rule = email_rule

    assert_no_difference -> { DebugLogEntry.where(category: "rule_notification").count } do
      rule.update!(active: true)
    end

    assert_not rule.notification_baseline_timed_out?
    assert rule.reload.active?
  end

  # Switching a rule on and adding its email action in one save takes the
  # baseline once, in Rule's callback. The action's commit callback must not
  # check again: a timeout there would switch off a rule that has its baseline.
  # (after_create_commit does not fire under transactional tests, so it is
  # invoked directly.)
  test "switching on and adding the email action in one save is baselined once" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction", active: false,
      conditions: [ name_condition("amzn") ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      rule.update!(active: true, actions_attributes: [ { action_type: "send_email_notification" } ])
    end
    action = rule.actions.find { |a| a.action_type == "send_email_notification" }
    assert_same rule, action.rule, "the action must see the rule the save went through"

    rule.stubs(:matching_transaction_ids).raises(Rule::SafeRegex::TimeoutError)
    assert_no_difference -> { DebugLogEntry.where(category: "rule_notification").count } do
      action.send(:seed_notification_baseline)
    end

    assert rule.reload.active?, "the rule already has its baseline"
  end

  test "a combined save whose baseline times out is reported once and leaves the rule off" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction", active: false,
      conditions: [ name_condition("amzn") ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )
    rule.stubs(:matching_transaction_ids).raises(Rule::SafeRegex::TimeoutError)

    assert_difference -> { DebugLogEntry.where(category: "rule_notification").count }, 1 do
      rule.update!(active: true, actions_attributes: [ { action_type: "send_email_notification" } ])
      rule.actions.find { |a| a.action_type == "send_email_notification" }.send(:seed_notification_baseline)
    end

    assert rule.notification_baseline_timed_out?
    assert_not rule.reload.active?
  end

  # The marker belongs to one save. A later save that takes no baseline clears
  # it, so an email action added after that still seeds its own.
  test "an email action added after a later save still takes its baseline" do
    rule = email_rule
    rule.update!(active: true)
    assert rule.notification_baseline_taken_in_this_save?
    rule.update!(name: "Renamed")
    NotificationDelivery.where(rule: rule).delete_all

    # Creating the action seeds its baseline from its own commit callback.
    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      rule.actions.create!(action_type: "send_email_notification")
    end
  end

  # Rule's callback runs on update only, so a rule created already on relies on
  # its email action for the baseline. The column defaults to false, so this
  # save also reads as active changing from false to true.
  test "a rule created already on still takes its baseline from the email action" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction", active: true,
      conditions: [ name_condition("amzn") ],
      actions: [ Rule::Action.new(action_type: "send_email_notification") ]
    )
    NotificationDelivery.where(rule: rule).delete_all
    assert rule.saved_change_to_active?(from: false, to: true), "precondition: the create reads as a switch-on"

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      rule.actions.first.send(:seed_notification_baseline)
    end
  end

  private
    def email_rule(condition: name_condition("amzn"))
      rule = Rule.create!(
        family: @family, resource_type: "transaction", active: false,
        conditions: [ condition ],
        actions: [ Rule::Action.new(action_type: "send_email_notification") ]
      )
      NotificationDelivery.where(rule: rule).delete_all
      rule
    end

    def name_condition(value)
      Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: value)
    end
end
