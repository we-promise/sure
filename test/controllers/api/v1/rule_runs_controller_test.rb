# frozen_string_literal: true

require "test_helper"

class Api::V1::RuleRunsControllerTest < ActionDispatch::IntegrationTest
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
    @redis = Redis.new
    @redis.del("api_rate_limit:#{@api_key.id}")

    @rule = @family.rules.build(
      name: "Coffee cleanup",
      resource_type: "transaction",
      active: true,
      effective_date: Date.new(2024, 1, 1)
    )
    @rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "coffee")
    @rule.actions.build(action_type: "set_transaction_name", value: "Coffee")
    @rule.save!

    @rule_run = @rule.rule_runs.create!(
      rule_name: @rule.name,
      execution_type: "manual",
      status: "success",
      transactions_queued: 10,
      transactions_processed: 10,
      transactions_modified: 4,
      pending_jobs_count: 0,
      executed_at: Time.zone.parse("2024-01-15 12:00:00")
    )
    @failed_rule_run = @rule.rule_runs.create!(
      rule_name: @rule.name,
      execution_type: "scheduled",
      status: "failed",
      transactions_queued: 5,
      transactions_processed: 2,
      transactions_modified: 0,
      pending_jobs_count: 0,
      executed_at: Time.zone.parse("2024-01-16 12:00:00"),
      error_message: "Rule failed"
    )
  end

  test "lists rule runs scoped to family rules" do
    other_rule_run = create_other_family_rule_run

    get api_v1_rule_runs_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    rule_run_ids = response_data["data"].map { |rule_run| rule_run["id"] }

    assert_includes rule_run_ids, @rule_run.id
    assert_includes rule_run_ids, @failed_rule_run.id
    assert_not_includes rule_run_ids, other_rule_run.id
    expected_count = RuleRun.joins(:rule).where(rules: { family_id: @family.id }).count
    assert_equal expected_count, response_data["meta"]["total_count"]
  end

  test "shows a rule run" do
    get api_v1_rule_run_url(@rule_run), headers: api_headers(@api_key)

    assert_response :success
    rule_run = JSON.parse(response.body)["data"]

    assert_equal @rule_run.id, rule_run["id"]
    assert_equal @rule.id, rule_run["rule_id"]
    assert_equal "manual", rule_run["execution_type"]
    assert_equal "success", rule_run["status"]
    assert_equal 10, rule_run["transactions_queued"]
    assert_equal 4, rule_run["transactions_modified"]
    assert_equal @rule.id, rule_run.dig("rule", "id")
  end

  test "does not show another family's rule run" do
    other_rule_run = create_other_family_rule_run

    get api_v1_rule_run_url(other_rule_run), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed rule run id" do
    get api_v1_rule_run_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters rule runs" do
    get api_v1_rule_runs_url,
        params: {
          rule_id: @rule.id,
          status: "failed",
          execution_type: "scheduled",
          start_executed_at: "2024-01-16T00:00:00Z",
          end_executed_at: "2024-01-17T00:00:00Z"
        },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @failed_rule_run.id ], response_data["data"].map { |rule_run| rule_run["id"] }
  end

  test "rejects invalid filters" do
    get api_v1_rule_runs_url, params: { status: "unknown" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "clamps oversized per_page values to the documented maximum" do
    get api_v1_rule_runs_url, params: { per_page: 500 }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 100, response_data["meta"]["per_page"]
  end

  test "rejects malformed rule_id filter" do
    get api_v1_rule_runs_url, params: { rule_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid timestamp filters" do
    get api_v1_rule_runs_url, params: { start_executed_at: "not-a-date" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_rule_runs_url

    assert_response :unauthorized
  end

  test "show requires authentication" do
    get api_v1_rule_run_url(@rule_run)

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_rule_runs_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  teardown do
    @redis&.close
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def create_other_family_rule_run
      other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
      other_rule = other_family.rules.build(name: "Other", resource_type: "transaction", active: true)
      other_rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "other")
      other_rule.actions.build(action_type: "set_transaction_name", value: "Other")
      other_rule.save!
      other_rule.rule_runs.create!(
        rule_name: other_rule.name,
        execution_type: "manual",
        status: "success",
        transactions_queued: 1,
        transactions_processed: 1,
        transactions_modified: 1,
        pending_jobs_count: 0,
        executed_at: Time.current
      )
    end
end
