require "test_helper"

class FeedbackHelperTest < ActionView::TestCase
  setup do
    @config = Rails.configuration.x.posthog
    @project = { api_key: "public-test-token", host: "https://feedback.example.test" }.freeze
    @config.stubs(:self_hosted_feedback_project).returns(@project)
    @config.stubs(:feedback_enabled).returns(true)
    @config.stubs(:development_enabled).returns(false)
    Rails.env.stubs(:production?).returns(true)
  end

  test "managed tracking does not initialize a separate project" do
    stubs(:self_hosted?).returns(false)
    assert_empty sankey_tracking_config
  end

  test "self-hosted tracking preserves the operator opt-out" do
    stubs(:self_hosted?).returns(true)
    assert_equal @project, sankey_tracking_config
    @config.stubs(:feedback_enabled).returns(false)
    assert_empty sankey_tracking_config
  end

  test "development tracking requires explicit opt-in and stays disabled in tests" do
    stubs(:self_hosted?).returns(true)
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(true)
    assert_empty sankey_tracking_config
    @config.stubs(:development_enabled).returns(true)
    assert_equal @project, sankey_tracking_config
    Rails.env.stubs(:development?).returns(false)
    assert_empty sankey_tracking_config
  end
end
