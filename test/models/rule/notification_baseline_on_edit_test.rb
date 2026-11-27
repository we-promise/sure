require "test_helper"

# An email rule records the transactions it already matches as delivered, so it
# only ever emails what appears afterwards. These tests cover edits that change
# WHICH transactions the rule matches: the baseline has to be taken again, or the
# next run emails every older transaction the edited rule now reaches.
class Rule::NotificationBaselineOnEditTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Baseline test", balance: 1000, currency: "USD", accountable: Depository.new)
    @coffee = create_transaction(date: 90.days.ago.to_date, account: @account, amount: 10, name: "Coffee shop").transaction
    @tea = create_transaction(date: 60.days.ago.to_date, account: @account, amount: 20, name: "Tea house").transaction
  end

  test "widening an active email rule's condition does not email existing matches" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ])
    assert_equal [ @coffee.id ], delivered_ids(rule)

    rows_before = NotificationDelivery.where(rule: rule).count
    assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, value: "house" } ])
    rows_after_edit = NotificationDelivery.where(rule: rule).count

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal 1, rows_after_edit - rows_before, "the edit should record the newly matched transaction"
    assert_equal [ @coffee.id, @tea.id ].sort, delivered_ids(rule)
  end

  test "clearing the effective date does not email existing matches" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ], effective_date: 30.days.ago.to_date)
    assert_equal [], delivered_ids(rule), "Coffee shop is older than the effective date, so the baseline is empty"

    assert rule.update(effective_date: nil)

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @coffee.id ], delivered_ids(rule)
  end

  test "moving the effective date earlier does not email existing matches" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ], effective_date: 30.days.ago.to_date)
    assert_equal [], delivered_ids(rule)

    assert rule.update(effective_date: 120.days.ago.to_date)

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @coffee.id ], delivered_ids(rule)
  end

  test "a new transaction after the widening edit is still emailed" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ])
    assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, value: "house" } ])

    guest_house = create_transaction(date: Date.current, account: @account, amount: 30, name: "Guest house").transaction

    assert_equal [ guest_house.id ], emailed_ids(rule) { run_rule(rule) }
  end

  test "changing a condition's operator does not email existing matches" do
    # "=" is an exact match, so "house" matches nothing until it becomes "contains".
    rule = create_email_rule(conditions: [ name_condition("house", operator: "=") ])
    assert_equal [], delivered_ids(rule)

    assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, operator: "like" } ])

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @tea.id ], delivered_ids(rule)
  end

  test "changing a condition's type does not email existing matches" do
    # No transaction has notes, so the notes condition matches nothing.
    rule = create_email_rule(conditions: [ { condition_type: "transaction_notes", operator: "like", value: "house" } ])
    assert_equal [], delivered_ids(rule)

    assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, condition_type: "transaction_name" } ])

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @tea.id ], delivered_ids(rule)
  end

  test "removing a condition does not email existing matches" do
    rule = create_email_rule(conditions: [ name_condition("o"), name_condition("coffee") ])
    assert_equal [ @coffee.id ], delivered_ids(rule)
    narrowing = rule.conditions.find_by!(value: "coffee")

    assert rule.update(conditions_attributes: [ { id: narrowing.id, _destroy: "1" } ])

    assert_not_includes emailed_ids(rule) { run_rule(rule) }, @tea.id
    assert_includes delivered_ids(rule), @tea.id
  end

  test "widening a compound sub-condition does not email existing matches" do
    rule = create_email_rule(conditions: [ compound_condition("and", name_condition("coffee")) ])
    assert_equal [ @coffee.id ], delivered_ids(rule)
    group = rule.conditions.first

    assert rule.update(conditions_attributes: [
      { id: group.id, sub_conditions_attributes: [ { id: group.sub_conditions.first.id, value: "house" } ] }
    ])

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @coffee.id, @tea.id ].sort, delivered_ids(rule)
  end

  test "adding a sub-condition to an any-of group does not email existing matches" do
    rule = create_email_rule(conditions: [ compound_condition("or", name_condition("coffee")) ])
    assert_equal [ @coffee.id ], delivered_ids(rule)

    assert rule.update(conditions_attributes: [
      { id: rule.conditions.first.id, sub_conditions_attributes: [ name_condition("house") ] }
    ])

    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_equal [ @coffee.id, @tea.id ].sort, delivered_ids(rule)
  end

  test "editing an inactive email rule then applying all rules does not email history" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ], active: false)
    assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, value: "house" } ])

    emailed = emailed_ids(rule) { ApplyAllRulesJob.perform_now(@family) }

    assert_equal [], emailed
    assert_not rule.reload.active?
  end

  test "the new baseline is written inside the edit's transaction" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ])

    Rule.transaction do
      assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, value: "house" } ])

      # Before the edit commits, the new conditions already come with their baseline.
      assert_includes delivered_ids(rule), @tea.id
    end
  end

  # Review of we-promise/sure#4150 (Codex, P1). Family::DataImporter clears an
  # existing rule's conditions with destroy_all before it saves, so an import with
  # no conditions left nothing for the rule to see changing, and a rule with no
  # conditions matches every transaction.
  test "a Sure re-import that removes every condition does not email existing matches" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ])
    assert_equal [ @coffee.id ], delivered_ids(rule)

    session = @family.import_sessions.create!(expected_chunks: 1)
    session.source_mappings.create!(family: @family, source_type: "Rule", source_id: "rule-1", target: rule)
    ndjson = {
      type: "Rule", version: 1,
      data: { id: "rule-1", name: "Everything", resource_type: "transaction", active: true,
              conditions: [], actions: [ { action_type: "send_email_notification" } ] }
    }.to_json
    Family::DataImporter.new(@family, ndjson, import_session: session).import!
    assert_empty rule.reload.conditions, "precondition: the import left the rule with no conditions"

    # With no conditions the rule matches every transaction the family has, so the
    # new baseline holds more than these two; Tea house joining it is the change.
    assert_equal [], emailed_ids(rule) { run_rule(rule) }
    assert_includes delivered_ids(rule), @tea.id
  end

  # Review of we-promise/sure#4150 (CodeRabbit). The importer replaces every
  # condition, so each one reads as changing even when the record holds the same
  # criteria. Re-seeding then would record a match still waiting for the next run
  # as delivered, and it would never be emailed.
  test "an identical Sure re-import still emails a pending match" do
    rule = create_email_rule(conditions: [ compound_condition("and", name_condition("coffee"), name_condition("o")) ])
    assert_equal [ @coffee.id ], delivered_ids(rule)
    coffee_bar = create_transaction(date: Date.current, account: @account, amount: 5, name: "Coffee bar").transaction

    session = @family.import_sessions.create!(expected_chunks: 1)
    session.source_mappings.create!(family: @family, source_type: "Rule", source_id: "rule-1", target: rule)
    ndjson = {
      type: "Rule", version: 1,
      data: { id: "rule-1", name: "Coffee alerts", resource_type: "transaction", active: true,
              conditions: [ { condition_type: "compound", operator: "and",
                              sub_conditions: [ name_condition("o"), name_condition("coffee") ] } ],
              actions: [ { action_type: "send_email_notification" } ] }
    }.to_json

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      Family::DataImporter.new(@family, ndjson, import_session: session).import!
    end
    assert_equal "Coffee alerts", rule.reload.name, "precondition: the import updated this rule"

    assert_equal [ coffee_bar.id ], emailed_ids(rule) { run_rule(rule) }
  end

  test "renaming an email rule does not re-seed" do
    rule = create_email_rule(conditions: [ name_condition("coffee") ])
    coffee_bar = create_transaction(date: Date.current, account: @account, amount: 5, name: "Coffee bar").transaction

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      assert rule.update(name: "Coffee alerts")
    end

    assert_equal [ coffee_bar.id ], emailed_ids(rule) { run_rule(rule) }
  end

  test "resubmitting a valueless condition's blank value does not re-seed" do
    # An import stores a valueless condition's value as nil; the form's hidden
    # value field sends it back as "". Both mean "no value".
    rule = create_email_rule(conditions: [ name_condition("coffee"), { condition_type: "transaction_notes", operator: "is_null", value: nil } ])
    valueless = rule.conditions.find_by!(condition_type: "transaction_notes")
    assert_nil valueless.value
    coffee_bar = create_transaction(date: Date.current, account: @account, amount: 5, name: "Coffee bar").transaction

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      assert rule.update(conditions_attributes: [ { id: valueless.id, condition_type: "transaction_notes", operator: "is_null", value: "" } ])
    end

    assert_equal [ coffee_bar.id ], emailed_ids(rule) { run_rule(rule) }
  end

  test "editing a rule without an email action writes no notification deliveries" do
    category = @family.categories.first
    rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      conditions_attributes: [ name_condition("coffee") ],
      actions_attributes: [ { action_type: "set_transaction_category", value: category.id } ]
    )

    assert_no_difference -> { NotificationDelivery.count } do
      assert rule.update(conditions_attributes: [ { id: rule.conditions.first.id, value: "house" } ])
    end
  end

  private
    def create_email_rule(conditions:, active: true, effective_date: nil)
      rule = @family.rules.create!(
        resource_type: "transaction",
        active: active,
        effective_date: effective_date,
        conditions_attributes: conditions,
        actions_attributes: [ { action_type: "send_email_notification" } ]
      )

      Rule.find(rule.id)
    end

    def name_condition(value, operator: "like")
      { condition_type: "transaction_name", operator: operator, value: value }
    end

    def compound_condition(operator, *sub_conditions)
      { condition_type: "compound", operator: operator, sub_conditions_attributes: sub_conditions }
    end

    # A run as RuleJob performs it, on a freshly loaded rule.
    def run_rule(rule)
      RuleJob.perform_now(Rule.find(rule.id))
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
