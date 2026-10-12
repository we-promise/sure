require "application_system_test_case"

class RulesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
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

  test "reorders rules with the keyboard" do
    family = @user.family
    family.rules.destroy_all
    first = family.rules.create!(name: "First rule", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    second = family.rules.create!(name: "Second rule", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    visit rules_path

    grip = find("[data-sortable-list-id='#{first.id}'] button[data-action*='handleKeyDown']")
    grip.send_keys(:enter)
    grip.send_keys(:arrow_down)
    grip.send_keys(:enter)

    assert_selector "[data-sortable-list-target='item']:first-child[data-sortable-list-id='#{second.id}']"
    # The order is saved by a fetch Capybara cannot wait on, so poll for it.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    sleep 0.05 until family.rules.ordered.pluck(:id) == [ second.id, first.id ] ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal [ second.id, first.id ], family.rules.ordered.pluck(:id)
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

  test "fixed split summary follows edits to the exact amount condition" do
    rule = @user.family.rules.create!(
      name: "Fixed split",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_amount", operator: "=", value: "100")
      ],
      actions: [
        Rule::Action.new(
          action_type: "split_transaction",
          value: {
            splits: [
              { type: "fixed", name: "A", share: "70" },
              { type: "fixed", name: "B", share: "30" }
            ]
          }.to_json
        )
      ]
    )

    visit edit_rule_path(rule)

    within "dialog" do
      summary = find("[data-rule--split-action-target='summary']")
      assert_selector "[data-rule--split-action-target='summary'].text-success", text: "100.00 / 100.00"

      find("[data-rules-target='conditionsList'] input[name$='[value]']").fill_in(with: "120")

      assert_selector "[data-rule--split-action-target='summary'].text-destructive", text: "100.00 / 120.00"
      assert_no_selector "[data-rule--split-action-target='summary'].text-success"
      assert_equal "100.00 / 120.00", summary.text
    end
  end

  test "split rows save category, merchant and tags picked in the rule form" do
    merchant = @user.family.merchants.create!(name: "Split Landlord")
    rule = @user.family.rules.create!(
      name: "Percentage split",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "rent")
      ],
      actions: [
        Rule::Action.new(
          action_type: "split_transaction",
          value: {
            splits: [
              { type: "percentage", name: "Mine", share: "50" },
              { type: "percentage", name: "Theirs", share: "50" }
            ]
          }.to_json
        )
      ]
    )

    visit edit_rule_path(rule)

    within "dialog" do
      first_row = all("[data-rule--split-action-target='row']", minimum: 2).first

      within first_row do
        find("select[aria-label='Split category']").select(categories(:food_and_drink).name)
        find("select[aria-label='Split merchant']").select(merchant.name)
        find("button[aria-label='Split tags']").click
        find("[role='option'][data-tag-name='#{tags(:one).name}']").click
        # Wait for the picked tag to land in the trigger, then close the menu so it can't sit
        # over the submit button on a slower runner.
        find("[data-tag-select-target='selectionContainer']", text: tags(:one).name)
        find("button[aria-label='Split tags']").click
        assert_no_selector "[data-tag-select-target='menu']", visible: true
      end

      click_button "Update Rule"
    end

    assert_text "Rule updated", wait: 10

    mine = JSON.parse(rule.reload.actions.sole.value)["splits"].first
    assert_equal categories(:food_and_drink).id, mine["category_id"]
    assert_equal merchant.id, mine["merchant_id"]
    assert_equal [ tags(:one).id ], mine["tag_ids"]
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
