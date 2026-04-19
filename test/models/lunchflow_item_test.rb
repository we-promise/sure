require "test_helper"

class LunchflowItemTest < ActiveSupport::TestCase
  def setup
    @lunchflow_item = lunchflow_items(:one)
  end

  test "effective_base_url returns default when base_url blank" do
    @lunchflow_item.base_url = nil
    assert_equal "https://lunchflow.app/api/v1", @lunchflow_item.effective_base_url
  end

  test "effective_base_url returns base_url when in allowlist" do
    @lunchflow_item.base_url = "https://lunchflow.app/api/v1"
    assert_equal "https://lunchflow.app/api/v1", @lunchflow_item.effective_base_url
  end

  test "effective_base_url rejects unknown base_url and falls back to default (F-08 SSRF)" do
    @lunchflow_item.base_url = "http://169.254.169.254/latest/meta-data"
    Rails.logger.expects(:warn).with(regexp_matches(/\[SECURITY\] Rejected Lunchflow base_url/))
    assert_equal LunchflowItem::ALLOWED_BASE_URLS.first, @lunchflow_item.effective_base_url
  end
end
