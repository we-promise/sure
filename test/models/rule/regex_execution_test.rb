require "test_helper"

# A regex rule runs under a statement timeout. The matching ids are resolved
# inside that bound and the actions then run on those ids, so the unbounded part
# of the rule (the pattern) is the only part that is limited.
class Rule::RegexExecutionTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Regex run", balance: 1000, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Shopping")
    @hit = create_transaction(date: Date.current, account: @account, name: "AMZN Mktp US")
    @miss = create_transaction(date: Date.current, account: @account, name: "Corner shop")
  end

  test "a regex rule applies to the matching rows only" do
    rule = regex_rule('^amzn\s')

    assert_equal 1, rule.apply

    assert_equal @category, @hit.reload.transaction.category
    assert_nil @miss.reload.transaction.category
  end

  # A pattern is bound as written, so it is matched against the name as stored:
  # collapsing the name's whitespace would leave a pattern that spells out a
  # run of spaces, a tab or an edge with nothing to match.
  test "a regex matches the name as stored, whitespace included" do
    spaced = create_transaction(date: Date.current, account: @account, name: "POS  PURCHASE 4411")
    edged = create_transaction(date: Date.current, account: @account, name: " Leading space")

    assert_equal [ spaced.entryable_id ], regex_rule("POS  PURCHASE").matching_scope.pluck(:id)
    assert_equal [ spaced.entryable_id ], regex_rule('POS\s{2}PURCHASE').matching_scope.pluck(:id)
    assert_equal [ edged.entryable_id ], regex_rule('^\sleading').matching_scope.pluck(:id)
  end

  test "a regex with one space does not match a name holding two" do
    create_transaction(date: Date.current, account: @account, name: "POS  PURCHASE 4411")

    assert_empty regex_rule("POS PURCHASE").matching_scope.pluck(:id)
    assert_equal 1, regex_rule('POS\s+PURCHASE').matching_scope.count
  end

  test "a regex rule resolves its matches under the timeout" do
    rule = regex_rule("amzn")

    Rule::SafeRegex.expects(:with_timeout).yields.once

    rule.apply
  end

  test "a rule without a regex condition does not use the timeout" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "amzn") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )

    Rule::SafeRegex.expects(:with_timeout).never

    assert_equal 1, rule.apply
  end

  # Rule#apply resolves its scope once and hands it to every action, so a broad
  # pattern is scanned (and materialised) once, not once per action.
  test "a regex is resolved once per apply however many actions the rule has" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "amzn") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: @category.id),
        Rule::Action.new(action_type: "exclude_transaction")
      ]
    )
    calls = 0
    Rule::SafeRegex.stubs(:with_timeout).with { |*| calls += 1; true }.yields.returns([ @hit.transaction.id ])

    rule.apply

    assert_equal 1, calls
    assert_equal @category, @hit.reload.transaction.category
    assert @hit.reload.excluded?, "the second action ran on the resolved match"
  end

  test "a later apply resolves the pattern again" do
    rule = regex_rule("amzn")
    calls = 0
    Rule::SafeRegex.stubs(:with_timeout).with { |*| calls += 1; true }.yields.returns([ @hit.transaction.id ])

    rule.apply
    rule.apply

    assert_equal 2, calls
  end

  test "a read after an apply resolves the pattern again" do
    rule = regex_rule("amzn")
    calls = 0
    Rule::SafeRegex.stubs(:with_timeout).with { |*| calls += 1; true }.yields.returns([ @hit.transaction.id ])

    rule.apply
    rule.matching_transaction_ids

    assert_equal 2, calls
  end

  # No stub on the timeout itself: a scope that really sleeps in Postgres is cancelled by
  # the statement timeout, and the error comes out of Rule#apply as TimeoutError.
  test "a regex rule whose match query outlives the limit is cancelled by Postgres and raises from apply" do
    rule = regex_rule("amzn")
    slow = rule.registry.resource_scope.where("(SELECT pg_sleep(1)) IS NOT NULL")
    Rule::Condition.any_instance.stubs(:apply).returns(slow)
    original = Rule::SafeRegex::EXECUTION_TIMEOUT_MS
    Rule::SafeRegex.send(:remove_const, :EXECUTION_TIMEOUT_MS)
    Rule::SafeRegex.const_set(:EXECUTION_TIMEOUT_MS, 30)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Rule::SafeRegex::TimeoutError) { rule.apply }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9, "the query ran to completion instead of being cancelled"
  ensure
    Rule::SafeRegex.send(:remove_const, :EXECUTION_TIMEOUT_MS)
    Rule::SafeRegex.const_set(:EXECUTION_TIMEOUT_MS, original)
  end

  test "a regex inside a compound condition is also bounded" do
    rule = Rule.new(family: @family, resource_type: "transaction",
                    actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ])
    compound = rule.conditions.build(condition_type: "compound", operator: "or")
    compound.sub_conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: "amzn")
    rule.save!

    Rule::SafeRegex.expects(:with_timeout).yields.once

    rule.apply
  end

  test "a timeout is raised from apply so the run is recorded as failed" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_raises(Rule::SafeRegex::TimeoutError) { rule.apply }

    assert_nil @hit.reload.transaction.category
  end

  # Rule::Runner records the failed run and RuleJob re-raises the requested rule's
  # error so the job is marked failed. For a timeout that would make Sidekiq retry
  # it, and the retry would time out again (and re-run every active rule above),
  # so the job is discarded instead; the failed run is the record of it.
  test "RuleJob records a failed run when the pattern times out, and does not raise for a retry" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_difference -> { rule.rule_runs.where(status: "failed").count }, 1 do
      assert_nothing_raised { RuleJob.perform_now(rule) }
    end
  end

  test "a rule whose pattern times out does not count as covering a transaction" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_not rule.matches_transaction?(@hit.transaction)
  end

  test "a regex rule reports whether it covers a transaction" do
    rule = regex_rule('^amzn\s')

    assert rule.matches_transaction?(@hit.transaction)
    assert_not rule.matches_transaction?(@miss.transaction)
  end

  # The prompt check asks about one transaction. Resolving the family's every
  # match first and then looking for that id scans the whole family per prompt.
  test "a regex rule's prompt check runs the pattern on that transaction only" do
    rule = regex_rule('^amzn\s')
    target = @hit.transaction

    queries = []
    callback = ->(*, payload) { queries << payload unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert rule.matches_transaction?(target)
    end

    regex_queries = queries.select { |payload| payload[:sql].include?("~*") }
    assert_equal 1, regex_queries.size, "the pattern runs once"

    regex_query = regex_queries.first
    assert_match(/"transactions"\."id" = (\$\d+|'#{target.id}')/, regex_query[:sql], "the regex query is filtered to one id")
    assert_includes Array(regex_query[:type_casted_binds]) + [ regex_query[:sql] ], target.id
  end

  test "the confirmation counts are 0 rather than an error when the pattern times out" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_equal 0, rule.affected_resource_count
    assert_equal 0, Rule.total_affected_resource_count([ rule ])
  end

  test "ApplyAllRulesJob carries on with the next rule after one times out" do
    slow = regex_rule("amzn", name: "slow")
    fine = Rule.create!(
      family: @family, resource_type: "transaction", name: "fine",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "shop") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_nothing_raised { ApplyAllRulesJob.perform_now(@family) }

    assert_equal 1, slow.rule_runs.where(status: "failed").count
    assert_equal 1, fine.rule_runs.where(status: "success").count
    assert_equal @category, @miss.reload.transaction.category
  end

  test "an email-notification action whose baseline times out is still created, and the rule is switched off" do
    rule = regex_rule("amzn")
    rule.update!(active: true)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    # after_create_commit does not fire under transactional tests, so the seeding
    # path is invoked directly (as send_email_notification_test.rb does).
    action = rule.actions.create!(action_type: "send_email_notification")
    assert_difference -> { DebugLogEntry.where(category: "rule_notification").count }, 1 do
      assert_nothing_raised { action.send(:seed_notification_baseline) }
    end
    assert_equal rule.id, DebugLogEntry.where(category: "rule_notification").last.metadata["rule_id"]

    # No baseline was recorded, so leaving the rule on would email every past match.
    assert_not rule.reload.active?
    assert_equal 0, NotificationDelivery.where(rule_id: rule.id).count
    assert action.persisted?
  end

  # Resolved ids go back into the query as one array parameter, as Rule::Runner
  # passes them (Rule#scope_for_transaction_ids). One bind per id would break past
  # PostgreSQL's 65,535-parameter limit on a broad pattern.
  test "a regex rule's matches are bound as one parameter however many there are" do
    rule = regex_rule("amzn|shop")
    one = bind_count { regex_rule("amzn").affected_resource_count }
    two = bind_count { assert_equal 2, rule.affected_resource_count }

    assert_equal one, two
  end

  # The ordered run (Rule::Runner) reads each rule's matches at its turn. A pattern
  # that times out fails that turn only: it claims and stops nothing, the rules
  # below it still run in order, and the timed-out rule sends no email.
  test "a pattern that times out in the ordered run fails its own turn only" do
    other = @family.categories.create!(name: "Other")
    timed_out = regex_rule("amzn", name: "timed out", active: true, stop_processing: true, email: true)
    stopper = ordered_rule("stopper", condition: name_condition("like", "amzn"), stop_processing: true,
                          action: Rule::Action.new(action_type: "set_transaction_category", value: other.id))
    below = ordered_rule("below", condition: name_condition("is_not_null", nil),
                         action: Rule::Action.new(action_type: "exclude_transaction"))
    assert_equal [ timed_out, stopper, below ].map(&:id), @family.rules.ordered.pluck(:id)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_no_difference -> { NotificationDelivery.where(rule: timed_out).count } do
      assert_no_enqueued_jobs(only: RuleEmailNotificationJob) do
        # One debug-log entry, for the one rule that failed.
        assert_difference -> { DebugLogEntry.where(category: "rule_run").count }, 1 do
          assert_nothing_raised { ApplyRulesJob.perform_now(@family) }
        end
      end
    end

    entry = DebugLogEntry.where(category: "rule_run").last
    assert_equal timed_out.id, entry.metadata["rule_id"]
    assert_equal @family, entry.family
    assert_equal [ "failed" ], timed_out.rule_runs.pluck(:status)
    assert_match "TimeoutError", timed_out.rule_runs.first.error_message
    assert_equal [ "success" ], stopper.rule_runs.pluck(:status)
    assert_equal [ "success" ], below.rule_runs.pluck(:status)
    assert_equal other, @hit.reload.transaction.category, "the rule below the timed-out one decided"
    assert_not @hit.reload.excluded?, "stop processing still held for the rule below"
    assert @miss.reload.excluded?
  end

  test "applying a rule below a pattern that times out records that failure and runs the rule" do
    timed_out = regex_rule("amzn", name: "timed out", active: true, stop_processing: true)
    below = ordered_rule("below", condition: name_condition("is_not_null", nil),
                         action: Rule::Action.new(action_type: "exclude_transaction"))
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_nothing_raised { RuleJob.perform_now(below) }

    assert_equal [ "failed" ], timed_out.rule_runs.pluck(:status)
    assert_equal [ "success" ], below.rule_runs.pluck(:status)
    assert @hit.reload.excluded?, "the timed-out rule above stopped nothing"
  end

  # The other half of the timeout contract: an email rule whose baseline timed out
  # when it was switched on is left off, so the sync's ordered run skips it even
  # once the pattern runs in time again, and its history is never emailed.
  test "an email rule left off by a timed-out baseline is skipped by the sync run" do
    rule = regex_rule("amzn", email: true)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)
    rule.update!(active: true)
    assert_not rule.reload.active?
    Rule::SafeRegex.unstub(:with_timeout)

    assert_no_enqueued_jobs(only: RuleEmailNotificationJob) do
      assert_no_difference -> { RuleRun.where(rule: rule).count } do
        ApplyRulesJob.perform_now(@family)
      end
    end
    assert_equal 0, NotificationDelivery.where(rule: rule).count
  end

  private
    def regex_rule(pattern, name: nil, active: false, stop_processing: false, email: false)
      actions = [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
      actions << Rule::Action.new(action_type: "send_email_notification") if email

      rule = Rule.create!(
        family: @family, resource_type: "transaction", name: name, active: active, stop_processing: stop_processing,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: pattern) ],
        actions: actions
      )
      # A create-time baseline (if the action records one) is cleared, so each
      # test states the baseline it relies on.
      NotificationDelivery.where(rule: rule).delete_all
      rule
    end

    def ordered_rule(name, condition:, action:, stop_processing: false)
      Rule.create!(
        family: @family, resource_type: "transaction", name: name, active: true, stop_processing: stop_processing,
        conditions: [ condition ], actions: [ action ]
      )
    end

    def name_condition(operator, value)
      Rule::Condition.new(condition_type: "transaction_name", operator: operator, value: value)
    end

    def bind_count
      binds = []
      callback = ->(*, payload) { binds << Array(payload[:binds]).size if payload[:sql].include?("COUNT") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      binds.last
    end
end
