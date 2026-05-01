# frozen_string_literal: true

require "test_helper"

class Api::V1::RulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")

    @rule = @family.rules.build(
      name: "Coffee cleanup",
      resource_type: "transaction",
      active: true,
      effective_date: Date.new(2024, 1, 1)
    )
    @rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "coffee")
    @rule.actions.build(action_type: "set_transaction_name", value: "Coffee")
    @rule.save!
  end

  test "should list rules" do
    get api_v1_rules_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response["data"].any? { |rule| rule["id"] == @rule.id }
    assert_equal @family.rules.count, json_response["meta"]["total_count"]
  end

  test "should not list another family's rules" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_rule = other_family.rules.build(name: "Other", resource_type: "transaction", active: true)
    other_rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "other")
    other_rule.actions.build(action_type: "set_transaction_name", value: "Other")
    other_rule.save!

    get api_v1_rules_url, headers: api_headers(@api_key)
    assert_response :success

    rule_ids = JSON.parse(response.body)["data"].map { |rule| rule["id"] }
    assert_includes rule_ids, @rule.id
    assert_not_includes rule_ids, other_rule.id
  end

  test "should require authentication when listing rules" do
    get api_v1_rules_url

    assert_response :unauthorized
  end

  test "should require read scope when listing rules" do
    api_key_without_read = api_key_without_read_scope

    get api_v1_rules_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
    json_response = JSON.parse(response.body)
    assert_equal "insufficient_scope", json_response["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should filter rules by active status" do
    inactive_rule = @family.rules.build(name: "Inactive", resource_type: "transaction", active: false)
    inactive_rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "ignore")
    inactive_rule.actions.build(action_type: "set_transaction_name", value: "Ignore")
    inactive_rule.save!

    get api_v1_rules_url, params: { active: true }, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    rule_ids = json_response["data"].map { |rule| rule["id"] }
    assert_includes rule_ids, @rule.id
    assert_not_includes rule_ids, inactive_rule.id
  end

  test "should reject invalid active filter" do
    get api_v1_rules_url, params: { active: "not_boolean" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
  end

  test "should reject unsupported resource type filter" do
    get api_v1_rules_url, params: { resource_type: "account" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
  end

  test "should show rule with conditions and actions" do
    get api_v1_rule_url(@rule), headers: api_headers(@api_key)
    assert_response :success

    rule = JSON.parse(response.body)["data"]
    assert_equal @rule.id, rule["id"]
    assert_equal "Coffee cleanup", rule["name"]
    assert_equal "transaction", rule["resource_type"]
    assert_equal true, rule["active"]
    assert_equal "2024-01-01", rule["effective_date"]

    assert_equal 1, rule["conditions"].length
    assert_equal "transaction_name", rule["conditions"].first["condition_type"]
    assert_equal "like", rule["conditions"].first["operator"]
    assert_equal "coffee", rule["conditions"].first["value"]

    assert_equal 1, rule["actions"].length
    assert_equal "set_transaction_name", rule["actions"].first["action_type"]
    assert_equal "Coffee", rule["actions"].first["value"]
  end

  test "should require authentication when showing a rule" do
    get api_v1_rule_url(@rule)

    assert_response :unauthorized
  end

  test "should require read scope when showing a rule" do
    api_key_without_read = api_key_without_read_scope

    get api_v1_rule_url(@rule), headers: api_headers(api_key_without_read)

    assert_response :forbidden
    json_response = JSON.parse(response.body)
    assert_equal "insufficient_scope", json_response["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should not show another family's rule" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_rule = other_family.rules.build(name: "Other", resource_type: "transaction", active: true)
    other_rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "other")
    other_rule.actions.build(action_type: "set_transaction_name", value: "Other")
    other_rule.save!

    get api_v1_rule_url(other_rule), headers: api_headers(@api_key)
    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "record_not_found", json_response["error"]
  end

  private

    def api_key_without_read_scope
      # Valid persisted API keys can only be read/read_write; this intentionally
      # bypasses validations to exercise the runtime insufficient-scope guard.
      ApiKey.new(
        user: @user,
        name: "No Read Key",
        scopes: [],
        display_key: "test_no_read_#{SecureRandom.hex(8)}",
        source: "mobile"
      ).tap { |api_key| api_key.save!(validate: false) }
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
