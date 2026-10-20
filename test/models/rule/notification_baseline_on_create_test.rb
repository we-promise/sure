require "test_helper"

# A "Send email notification" action records the transactions its rule already
# matches as delivered when it is created, so the rule only ever emails what
# appears afterwards. These tests cover the moments an email action comes into
# being: a new rule, an action added to an existing rule, and the importers.
class Rule::NotificationBaselineOnCreateTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Baseline", balance: 1000, currency: "USD", accountable: Depository.new)
    @cafe = create_transaction(date: 10.days.ago.to_date, account: @account, amount: 10, name: "Corner cafe").transaction
    @bakery = create_transaction(date: 5.days.ago.to_date, account: @account, amount: 20, name: "Cafe bakery").transaction
    @shop = create_transaction(date: 5.days.ago.to_date, account: @account, amount: 30, name: "Hardware shop").transaction
  end

  test "creating a rule with an email action records its current matches as the baseline" do
    rule = nil

    assert_difference -> { NotificationDelivery.count }, 2 do
      assert_no_enqueued_jobs(only: RuleEmailNotificationJob) do
        rule = create_rule(actions: [ { action_type: "send_email_notification" } ])
      end
    end

    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
  end

  test "a new email rule's first run emails nothing that matched before it" do
    rule = create_rule(actions: [ { action_type: "send_email_notification" } ])

    assert_equal [], emailed_ids(rule) { RuleJob.perform_now(Rule.find(rule.id)) }
  end

  test "a match that appears after the email rule is created is still emailed" do
    rule = create_rule(actions: [ { action_type: "send_email_notification" } ])
    later = create_transaction(date: Date.current, account: @account, amount: 5, name: "Cafe express").transaction

    assert_equal [ later.id ], emailed_ids(rule) { RuleJob.perform_now(Rule.find(rule.id)) }
  end

  test "adding an email action to an existing rule records the baseline" do
    rule = create_rule(actions: [ { action_type: "exclude_transaction" } ])
    assert_equal [], delivered_ids(rule)

    assert rule.update(actions_attributes: [ { action_type: "send_email_notification" } ])

    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
    assert_equal [], emailed_ids(rule) { RuleJob.perform_now(Rule.find(rule.id)) }
  end

  test "changing an existing action's type to email still records the baseline" do
    rule = create_rule(actions: [ { action_type: "exclude_transaction" } ])
    action = rule.actions.first

    assert rule.update(actions_attributes: [ { id: action.id, action_type: "send_email_notification" } ])

    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
  end

  test "creating a rule without an email action records nothing" do
    Rule.any_instance.expects(:matching_transaction_ids).never

    assert_no_difference -> { NotificationDelivery.count } do
      create_rule(actions: [ { action_type: "exclude_transaction" } ])
    end
  end

  test "editing an email action without changing its type does not record the baseline again" do
    rule = create_rule(actions: [ { action_type: "send_email_notification" } ])
    later = create_transaction(date: Date.current, account: @account, amount: 5, name: "Cafe express").transaction
    action = rule.actions.first

    Rule.any_instance.expects(:matching_transaction_ids).never
    assert rule.update(name: "Renamed", actions_attributes: [ { id: action.id, value: "" } ])

    assert_not_includes delivered_ids(rule), later.id
  end

  test "RuleImport records the baseline for a new email rule" do
    import_rules_csv("cafe")

    rule = @family.rules.find_by!(name: "Cafe alerts")
    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
    assert_equal [], emailed_ids(rule) { RuleJob.perform_now(rule) }
  end

  test "an identical RuleImport re-import keeps the baseline, so a pending match is still emailed" do
    import_rules_csv("cafe")
    rule = @family.rules.find_by!(name: "Cafe alerts")
    pending = create_transaction(date: Date.current, account: @account, amount: 5, name: "Cafe express").transaction

    import_rules_csv("cafe")

    assert_not_includes delivered_ids(rule), pending.id
    assert_equal [ pending.id ], emailed_ids(rule) { RuleJob.perform_now(Rule.find(rule.id)) }
  end

  test "a RuleImport re-import that adds an email action to an existing rule records the baseline" do
    import_rules_csv("cafe", action_type: "exclude_transaction")
    rule = @family.rules.find_by!(name: "Cafe alerts")
    assert_equal [], delivered_ids(rule)

    import_rules_csv("cafe")

    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
  end

  # Every row of an import shares one transaction. The second row for a rule
  # sees the email action the first row has only just written, uncommitted; the
  # first action is replaced before it commits, so nothing has recorded a
  # baseline for the second to keep.
  test "a RuleImport naming a new email rule twice still records its baseline" do
    import_rules_csv("cafe", rows: 2)

    rule = @family.rules.find_by!(name: "Cafe alerts")
    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
    assert_equal [], emailed_ids(rule) { RuleJob.perform_now(rule) }
  end

  test "a Sure import naming a new email rule twice still records its baseline" do
    Family::DataImporter.new(@family, [ rule_ndjson("cafe"), rule_ndjson("cafe") ].join("\n")).import!

    rule = @family.rules.find_by!(name: "Cafe alerts")
    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
    assert_equal [], emailed_ids(rule) { RuleJob.perform_now(rule) }
  end

  test "a Sure import records the baseline for a new email rule" do
    Family::DataImporter.new(@family, rule_ndjson("cafe")).import!

    rule = @family.rules.find_by!(name: "Cafe alerts")
    assert_equal [ @bakery.id, @cafe.id ].sort, delivered_ids(rule)
  end

  test "an identical Sure re-import keeps the baseline, so a pending match is still emailed" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    Family::DataImporter.new(@family, rule_ndjson("cafe"), import_session: session).import!
    rule = @family.rules.find_by!(name: "Cafe alerts")
    pending = create_transaction(date: Date.current, account: @account, amount: 5, name: "Cafe express").transaction

    Family::DataImporter.new(@family, rule_ndjson("cafe"), import_session: session).import!

    assert_equal rule.id, @family.rules.find_by!(name: "Cafe alerts").id, "the re-import should update the same rule"
    assert_not_includes delivered_ids(rule), pending.id
    assert_equal [ pending.id ], emailed_ids(rule) { RuleJob.perform_now(Rule.find(rule.id)) }
  end

  test "a rule reports a stored email action, even once it is marked for replacement" do
    rule = Rule.find(create_rule(actions: [ { action_type: "send_email_notification" } ]).id)

    rule.actions.each(&:mark_for_destruction)

    assert rule.stored_email_notification_action?
  end

  test "an email action that is only built, not stored, does not count as the rule's" do
    rule = create_rule(actions: [ { action_type: "exclude_transaction" } ])
    assert_not rule.stored_email_notification_action?

    rule.actions.build(action_type: "send_email_notification")
    assert_not rule.stored_email_notification_action?

    new_rule = @family.rules.build(resource_type: "transaction")
    new_rule.actions.build(action_type: "send_email_notification")
    assert_not new_rule.stored_email_notification_action?
  end

  private
    def create_rule(actions:)
      @family.rules.create!(
        name: "Cafe alerts",
        resource_type: "transaction",
        active: true,
        conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "cafe" } ],
        actions_attributes: actions
      )
    end

    def import_rules_csv(value, action_type: "send_email_notification", rows: 1)
      conditions = [ { condition_type: "transaction_name", operator: "like", value: value } ].to_json
      actions = [ { action_type: action_type } ].to_json
      csv = CSV.generate do |csv_rows|
        csv_rows << %w[name resource_type active effective_date conditions actions]
        rows.times { csv_rows << [ "Cafe alerts", "transaction", "true", "", conditions, actions ] }
      end

      import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
      import.generate_rows_from_csv
      import.send(:import!)
    end

    def rule_ndjson(value)
      {
        type: "Rule",
        version: 1,
        data: {
          id: "rule-cafe",
          name: "Cafe alerts",
          resource_type: "transaction",
          active: true,
          conditions: [ { condition_type: "transaction_name", operator: "like", value: value } ],
          actions: [ { action_type: "send_email_notification" } ]
        }
      }.to_json
    end

    def delivered_ids(rule)
      NotificationDelivery.where(rule: rule).pluck(:transaction_id).sort
    end

    # The transaction ids the block enqueued for emailing, for this rule only.
    def emailed_ids(rule)
      before = enqueued_jobs.size
      yield
      enqueued_jobs.drop(before)
        .select { |job| job[:job] == RuleEmailNotificationJob }
        .map { |job| ActiveJob::Arguments.deserialize(job[:args]) }
        .select { |rule_id, _| rule_id == rule.id }
        .flat_map(&:second)
        .sort
    end
end
