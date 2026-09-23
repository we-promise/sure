require "application_system_test_case"

class RulesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "offers swap deposit and withdrawal as a then action" do
    visit new_rule_path

    click_on "Add action"

    assert_selector "select[name*='[actions_attributes]'] option", text: "Swap deposit and withdrawal"
    assert_text "FOR"
  end

  test "shows queued processed modified and blocked counts for recent rule runs" do
    rule = @user.family.rules.create!(
      name: "Whole Foods Testing",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id)
      ]
    )

    rule.rule_runs.create!(
      rule_name: rule.name,
      execution_type: "manual",
      status: "success",
      transactions_queued: 20,
      transactions_processed: 20,
      transactions_modified: 10,
      pending_jobs_count: 0,
      executed_at: Time.current
    )

    visit rules_path

    assert_selector "th", text: /queued\s+processed\s+modified\s+blocked/i
    assert_selector "td", text: "20 / 20 / 10 / 10"
  end

  test "rules page renders gracefully when a condition has an unsupported condition_type" do
    @user.update!(locale: "de")
    rule = @user.family.rules.create!(
      name: "Legacy bad rule",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "x")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id)
      ]
    )

    # Simulate a legacy row written before the inclusion validation existed.
    rule.conditions.first.update_columns(condition_type: "name")

    visit rules_path

    assert_selector "h3", text: "Legacy bad rule"
    assert_text "Nicht unterstützt (name)"
  end

  test "creates a transaction rule through the modal with dynamically added condition and action" do
    visit new_rule_path(resource_type: "transaction")

    within "dialog" do
      click_on "Add condition"
      find("[data-rules-target='conditionsList'] input[name$='[value]']").fill_in(with: "Coffee")
      click_on "Add action"
      click_on "Create Rule"
    end

    # A successful create lands on the confirmation dialog; before the
    # nested-attribute keys were numeric, the submit failed validation with
    # "must have at least one action" because strong params dropped the rows.
    assert_text "Confirm changes"

    rule = Rule.order(:created_at).last
    assert_equal "transaction_name", rule.conditions.first.condition_type
    assert_equal "Coffee", rule.conditions.first.value
    assert_equal "set_transaction_category", rule.actions.first.action_type
    assert rule.actions.first.value.present?
  end
end
