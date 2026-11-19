require "test_helper"

class Transactions::MatchingRulesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
    @family = @user.family
    @family.rules.destroy_all
  end

  test "the drawer loads matching rules lazily inside a closed disclosure" do
    create_rule(name: "Coffee", value: "starbucks", category: categories(:income))

    queries = capture_sql_queries do
      get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }
    end

    assert_response :success
    assert_select "details:not([open]) turbo-frame##{dom_id(@entry, :matching_rules)}[loading=lazy][src=?]",
                  transaction_matching_rules_path(@entry)
    assert_not queries.any? { |sql| sql.include?("UNION ALL") }, "the drawer must not evaluate rules"
  end

  test "lists matching rules with what they set and a link to edit them" do
    rule = create_rule(name: "Coffee", value: "starbucks", category: categories(:income))
    create_rule(name: "Streaming", value: "netflix", category: categories(:income))

    get transaction_matching_rules_url(@entry)

    assert_response :success
    assert_select "turbo-frame##{dom_id(@entry, :matching_rules)}" do
      assert_select "[data-testid='matching-rule']", count: 1
      assert_select "[data-testid='matching-rule']", text: /Coffee/
      assert_select "[data-testid='matching-rule']", text: /Income/
      assert_select "a[href=?][data-turbo-frame=modal]", edit_rule_path(rule)
    end
    assert_no_match "Streaming", response.body
  end

  test "names an unnamed rule by its condition" do
    create_rule(name: nil, value: "starbucks", category: categories(:income))

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rule']", text: /starbucks/
  end

  test "labels switched-off rules" do
    create_rule(name: "Old coffee", value: "starbucks", category: categories(:income), active: false)

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rule']", text: /Old coffee/
    assert_select "[data-testid='matching-rule']", text: /Off/
  end

  test "flags rules that set the category to different values" do
    create_rule(name: "Coffee", value: "starbucks", category: categories(:income))
    create_rule(name: "Food", value: "star", category: categories(:food_and_drink))

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rules-conflict']", text: /category/i
    assert_select "[data-testid='matching-rule']", text: /Overridden/, count: 1
  end

  test "marks rules a stop-processing rule above keeps from running" do
    create_rule(name: "Coffee", value: "starbucks", category: categories(:income)).update!(stop_processing: true)
    create_rule(name: "Food", value: "star", category: categories(:food_and_drink))

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rule']", text: /Not reached/, count: 1
    assert_select "[data-testid='matching-rules-conflict']", count: 0
  end

  test "shows the value a rename rule sets" do
    rule = @family.rules.build(name: "Rename", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "starbucks")
    rule.actions.build(action_type: "set_transaction_name", value: "Morning coffee")
    rule.save!

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rule']", text: /Morning coffee/
  end

  test "says when the category was set by hand" do
    create_rule(name: "Coffee", value: "starbucks", category: categories(:income))
    @entry.transaction.lock_attr!(:category_id)

    get transaction_matching_rules_url(@entry)

    assert_select "[data-testid='matching-rules-locked']", text: /category/
  end

  test "says so when no rule matches" do
    create_rule(name: "Streaming", value: "netflix", category: categories(:income))

    get transaction_matching_rules_url(@entry)

    assert_response :success
    assert_select "[data-testid='matching-rule']", count: 0
    assert_select "turbo-frame##{dom_id(@entry, :matching_rules)}", text: /No rule matches/
  end

  test "guests see matching rules without edit links" do
    rule = create_rule(name: "Coffee", value: "starbucks", category: categories(:income))
    @entry.account.update!(owner: family_guest)
    sign_in family_guest

    get transaction_matching_rules_url(@entry)

    assert_response :success
    assert_select "[data-testid='matching-rule']", text: /Coffee/
    assert_select "a[href=?]", edit_rule_path(rule), count: 0
  end

  test "transactions in accounts the user cannot see are not found" do
    entry = create_transaction(account: accounts(:investment), name: "Starbucks")
    sign_in users(:family_member)

    get transaction_matching_rules_url(entry)

    assert_response :not_found
  end

  private
    def create_rule(name:, value:, category:, active: true)
      rule = @family.rules.build(name: name, resource_type: "transaction", active: active)
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: value)
      rule.actions.build(action_type: "set_transaction_category", value: category.id)
      rule.save!
      rule
    end
end
