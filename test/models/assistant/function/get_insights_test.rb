require "test_helper"

class Assistant::Function::GetInsightsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetInsights.new(@user)
  end

  test "has correct name" do
    assert_equal "get_insights", @fn.name
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns visible insights with their metadata" do
    result = @fn.call

    assert result[:insights].any?

    anomaly = result[:insights].find { |i| i[:type] == "spending_anomaly" }

    assert_not_nil anomaly
    assert anomaly[:title].present?
    assert anomaly[:metadata].present?
  end

  test "excludes acknowledged insights by default and includes them on request" do
    acknowledged = @family.insights.first
    acknowledged.update!(status: "acknowledged")

    default_ids = @fn.call[:insights].map { |i| i[:id] }

    assert_not_includes default_ids, acknowledged.id

    included_ids = @fn.call("include_acknowledged" => true)[:insights].map { |i| i[:id] }

    assert_includes included_ids, acknowledged.id
  end

  test "filters by insight_type and clamps limit" do
    result = @fn.call("insight_type" => "cash_flow_warning", "limit" => 999)

    assert result[:insights].all? { |i| i[:type] == "cash_flow_warning" }
  end

  test "limit clamps to the maximum with more matching insights than the cap" do
    (Assistant::Function::GetInsights::MAX_LIMIT + 5).times do |i|
      @family.insights.create!(
        insight_type: "spending_anomaly",
        priority: "low",
        status: "active",
        title: "Clamp insight #{i}",
        body: "Body #{i}",
        currency: "USD",
        period_start: Date.current.beginning_of_month,
        period_end: Date.current.end_of_month,
        generated_at: Time.current,
        dedup_key: "clamp-test-#{i}"
      )
    end

    result = @fn.call("limit" => 999)

    assert_equal Assistant::Function::GetInsights::MAX_LIMIT, result[:insights].size
  end

  test "does not mutate insight status" do
    assert_no_changes -> { @family.insights.order(:id).pluck(:status) } do
      @fn.call
    end
  end

  test "does not return another family's insights" do
    result = Assistant::Function::GetInsights.new(users(:empty)).call

    assert_empty result[:insights]
  end
end
