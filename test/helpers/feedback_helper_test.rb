require "test_helper"

class FeedbackHelperTest < ActionView::TestCase
  setup do
    @config = Rails.configuration.x.posthog
    @surveys = {
      sankey: { managed: "managed-sankey", self_hosted: "shared-sankey" }.freeze,
      another_feature: { managed: "managed-other", self_hosted: "shared-other" }.freeze
    }.freeze
    @project = { api_key: "public-test-token", host: "https://feedback.example.test" }.freeze
    @config.stubs(:feedback_surveys).returns(@surveys)
    @config.stubs(:self_hosted_feedback_project).returns(@project)
    @config.stubs(:feedback_enabled).returns(true)
    Rails.env.stubs(:production?).returns(true)
  end

  test "managed features select their own surveys without initializing another project" do
    stubs(:self_hosted?).returns(false)
    @config.expects(:self_hosted_feedback_project).never
    assert_equal({ survey_id: "managed-sankey" }, feedback_config(:sankey))
    assert_equal({ survey_id: "managed-other" }, feedback_config(:another_feature))
  end

  test "self-hosted features share the public project but keep distinct surveys" do
    stubs(:self_hosted?).returns(true)
    assert_equal @project.merge(survey_id: "shared-sankey"), feedback_config(:sankey)
    assert_equal @project.merge(survey_id: "shared-other"), feedback_config(:another_feature)
    result = feedback_config(:sankey)
    result[:survey_id] = "changed-by-caller"
    assert_equal "shared-sankey", feedback_config(:sankey)[:survey_id]
    assert_not @project.key?(:survey_id)
  end

  test "unknown or unconfigured surveys never fall back to another destination" do
    @config.stubs(:feedback_surveys).returns(@surveys.merge(
      managed_only: { managed: "managed-only" },
      shared_only: { self_hosted: "shared-only" },
      blank: { managed: " ", self_hosted: "" }
    ))
    [ false, true ].each do |self_hosted|
      stubs(:self_hosted?).returns(self_hosted)
      assert_empty feedback_config(:unknown)
      assert_empty feedback_config(:blank)
      assert_empty feedback_config(self_hosted ? :managed_only : :shared_only)
    end
  end

  test "self-hosted feedback stays disabled outside production or after operator opt-out" do
    stubs(:self_hosted?).returns(true)
    Rails.env.stubs(:production?).returns(false)
    assert_empty feedback_config(:sankey)
    Rails.env.stubs(:production?).returns(true)
    @config.stubs(:feedback_enabled).returns(false)
    assert_empty feedback_config(:another_feature)
    stubs(:self_hosted?).returns(false)
    assert_equal({ survey_id: "managed-other" }, feedback_config(:another_feature))
  end
end
