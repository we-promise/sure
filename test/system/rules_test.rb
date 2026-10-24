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

    grip = find("[data-sortable-list-id='rule:#{first.id}'] button[data-action*='handleKeyDown']")
    grip.send_keys(:enter)
    grip.send_keys(:arrow_down)
    grip.send_keys(:enter)

    assert_selector "[data-sortable-list-target='item']:first-child[data-sortable-list-id='rule:#{second.id}']"
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

  test "moves a group with its rules and the rules inside it with the keyboard" do
    family = @user.family
    family.rules.destroy_all
    loose = create_exclude_rule("Loose rule")
    group = family.rule_groups.create!(name: "Food")
    first_in_group = create_exclude_rule("First in group", group: group)
    second_in_group = create_exclude_rule("Second in group", group: group)

    visit rules_path

    group_grip = find("[data-sortable-list-id='group:#{group.id}'] summary button[data-action*='handleKeyDown']")
    group_grip.send_keys(:enter)
    group_grip.send_keys(:arrow_up)
    group_grip.send_keys(:enter)
    wait_for_order(family, [ first_in_group.id, second_in_group.id, loose.id ])

    rule_grip = find("[data-sortable-list-id='#{second_in_group.id}'] button[data-action*='handleKeyDown']")
    rule_grip.send_keys(:enter)
    rule_grip.send_keys(:arrow_up)
    rule_grip.send_keys(:enter)
    wait_for_order(family, [ second_in_group.id, first_in_group.id, loose.id ])
  end

  test "drags a group past a rule and a rule inside its group with the mouse" do
    family = @user.family
    family.rules.destroy_all
    group = family.rule_groups.create!(name: "Food")
    first_in_group = create_exclude_rule("First in group", group: group)
    second_in_group = create_exclude_rule("Second in group", group: group)
    loose = create_exclude_rule("Loose rule")

    visit rules_path

    drag("[data-sortable-list-id='group:#{group.id}']", onto: "[data-sortable-list-id='rule:#{loose.id}']", side: :bottom)
    wait_for_order(family, [ loose.id, first_in_group.id, second_in_group.id ])

    # The drag starts on a rule of the nested list; only that list moves it.
    drag("[data-sortable-list-id='#{second_in_group.id}']", onto: "[data-sortable-list-id='#{first_in_group.id}']", side: :top)
    wait_for_order(family, [ loose.id, second_in_group.id, first_in_group.id ])
  end

  test "searches and filters rules and turns sorting off meanwhile" do
    family = @user.family
    family.rules.destroy_all
    group = family.rule_groups.create!(name: "Housing")
    groceries = create_exclude_rule("Groceries", active: false)
    rent = create_exclude_rule("Rent", group: group)

    visit rules_path
    find("input[type='search']").fill_in(with: "rent")

    assert_selector "[data-sortable-list-id='#{rent.id}']"
    assert_no_selector "[data-sortable-list-id='rule:#{groceries.id}']"
    assert_text "Sorting is off while a search or filter is active"
    assert_selector "[data-sortable-list-id='#{rent.id}'][draggable='false'] button[data-action*='handleKeyDown']:disabled", visible: :all
    assert_current_path(/q=rent/)

    click_on "Filter"
    click_on "Reset"
    assert_no_current_path(/q=rent/)
    click_on "Filter"
    within("#rule-filters-menu") do
      click_on "Status"
      choose "Inactive"
      click_on "Done"
    end

    assert_selector "[data-sortable-list-id='rule:#{groceries.id}']"
    assert_no_selector "[data-sortable-list-id='group:#{group.id}']"
    assert_current_path(/status=inactive/)

    within("[data-rules-filter-target='badge'][data-filter-param='status']") do
      assert_text(/Status:\s+Inactive/)
      find("button[aria-label='Remove filter Status']").click
    end

    assert_selector "[data-sortable-list-id='group:#{group.id}']"
    assert_no_current_path(/status=/)
  end

  test "folds a group and keeps it folded after a reload" do
    family = @user.family
    group = family.rule_groups.create!(name: "Food")
    rule = create_exclude_rule("Folded rule", group: group)

    visit rules_path
    find("[data-sortable-list-id='group:#{group.id}'] [data-rules-group-header]").click

    assert_no_selector "[data-sortable-list-id='#{rule.id}']"
    visit rules_path
    assert_selector "[data-sortable-list-id='group:#{group.id}'] details:not([open])"
    assert_no_selector "[data-sortable-list-id='#{rule.id}']"
  end

  test "folds a rule outside a group to its title and keeps it folded after a reload" do
    rule = create_exclude_rule("Loose rule")

    visit rules_path
    within("[data-sortable-list-id='rule:#{rule.id}']") do
      assert_text "THEN"
      find("button[aria-controls='#{ActionView::RecordIdentifier.dom_id(rule, :details)}']").click
      assert_text "Loose rule"
      assert_no_text "THEN"
    end

    visit rules_path
    within("[data-sortable-list-id='rule:#{rule.id}']") do
      assert_selector "button[aria-expanded='false']"
      assert_no_text "THEN"
    end
  end

  private
    def create_exclude_rule(name, group: nil, active: true)
      @user.family.rules.create!(name: name, resource_type: "transaction", rule_group: group, active: active,
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end

    # Selenium cannot drive native HTML drag and drop, so the drag events are
    # dispatched with the pointer near the top or bottom edge of the target.
    def drag(source, onto:, side:)
      page.execute_script(<<~JS, source, onto, side.to_s)
        const [sourceSelector, targetSelector, side] = arguments;
        const source = document.querySelector(sourceSelector);
        const target = document.querySelector(targetSelector);
        const box = target.getBoundingClientRect();
        const pointer = { clientX: box.left + box.width / 2, clientY: side === "top" ? box.top + 2 : box.bottom - 2 };
        const dataTransfer = new DataTransfer();
        const fire = (element, type, extra = {}) =>
          element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer, ...extra }));
        fire(source, "dragstart");
        fire(target, "dragover", pointer);
        fire(target, "drop", pointer);
        fire(source, "dragend");
      JS
    end

    # The order is saved by a fetch Capybara cannot wait on, so poll for it.
    def wait_for_order(family, ids)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
      sleep 0.05 until family.rules.ordered.pluck(:id) == ids ||
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_equal ids, family.rules.ordered.pluck(:id)
    end
end
