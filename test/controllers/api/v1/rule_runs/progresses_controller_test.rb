# frozen_string_literal: true

require "test_helper"

class Api::V1::RuleRuns::ProgressesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(user: @user, name: "Test Read Key", scopes: [ "read" ], source: "web",
                              display_key: "test_read_#{SecureRandom.hex(8)}")
    Redis.new.del("api_rate_limit:#{@api_key.id}")

    @rule = @user.family.rules.build(name: "AI merchants", resource_type: "transaction", active: true,
                                     effective_date: Date.new(2024, 1, 1))
    @rule.actions.build(action_type: "auto_detect_merchants")
    @rule.save!
    @rule_run = @rule.rule_runs.create!(rule_name: @rule.name, execution_type: "manual", status: "pending",
                                        transactions_queued: 50, transactions_processed: 50, pending_jobs_count: 1,
                                        executed_at: Time.current)
    @rule_run.await_ai!(50)
  end

  test "counts a run's transactions down as AI batches are applied" do
    get api_v1_rule_run_progress_url(@rule_run), headers: { "X-Api-Key" => @api_key.display_key }
    assert_response :success
    assert_equal({ "rule_run_id" => @rule_run.id, "status" => "pending", "transactions_queued" => 50,
                   "transactions_awaiting_ai" => 50, "transactions_modified" => 0, "finished" => false },
                 JSON.parse(response.body)["data"].except("updated_at"))

    @rule_run.ai_handled!(handled: 25, modified: 20)

    get api_v1_rule_run_progress_url(@rule_run), headers: { "X-Api-Key" => @api_key.display_key }
    progress = JSON.parse(response.body)["data"]
    assert_equal [ 25, 20, false ], progress.values_at("transactions_awaiting_ai", "transactions_modified", "finished")
  end

  test "a finished run reports nothing awaiting" do
    @rule_run.ai_handled!(handled: 50, modified: 30)
    @rule_run.complete_job!

    get api_v1_rule_run_progress_url(@rule_run), headers: { "X-Api-Key" => @api_key.display_key }

    progress = JSON.parse(response.body)["data"]
    assert_equal [ "success", 0, 30, true ], progress.values_at("status", "transactions_awaiting_ai", "transactions_modified", "finished")
  end

  test "another family's run is not found" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_rule = other_family.rules.build(name: "Other", resource_type: "transaction", active: true)
    other_rule.actions.build(action_type: "auto_detect_merchants")
    other_rule.save!
    other_run = other_rule.rule_runs.create!(rule_name: "Other", execution_type: "manual", status: "pending", executed_at: Time.current)

    get api_v1_rule_run_progress_url(other_run), headers: { "X-Api-Key" => @api_key.display_key }

    assert_response :not_found
  end

  test "requires an API key" do
    get api_v1_rule_run_progress_url(@rule_run)

    assert_response :unauthorized
  end
end
