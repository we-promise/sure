require "test_helper"

class LunchflowItemTest < ActiveSupport::TestCase
  def setup
    @lunchflow_item = lunchflow_items(:one)
  end

  test "effective_base_url returns default when base_url blank" do
    @lunchflow_item.base_url = nil

    assert_equal LunchflowItem::DEFAULT_BASE_URL, @lunchflow_item.effective_base_url
  end

  test "effective_base_url returns default for non-lunchflow host" do
    @lunchflow_item.base_url = "https://169.254.169.254/latest/meta-data"

    assert_equal LunchflowItem::DEFAULT_BASE_URL, @lunchflow_item.effective_base_url
  end

  test "effective_base_url returns default for non-https scheme" do
    @lunchflow_item.base_url = "http://lunchflow.app/api/v1"

    assert_equal LunchflowItem::DEFAULT_BASE_URL, @lunchflow_item.effective_base_url
  end

  test "effective_base_url returns canonical default for valid lunchflow url" do
    @lunchflow_item.base_url = "https://lunchflow.app/api/v1/"

    assert_equal LunchflowItem::DEFAULT_BASE_URL, @lunchflow_item.effective_base_url
  end

  test "sync status summary covers every German count branch" do
    assert_sync_status(:de, total: 0, linked: 0, unlinked: 0, expected: "Keine Konten gefunden")
    assert_sync_status(:de, total: 1, linked: 1, unlinked: 0, expected: "1 Konto synchronisiert")
    assert_sync_status(:de, total: 2, linked: 2, unlinked: 0, expected: "2 Konten synchronisiert")
    assert_sync_status(:de, total: 2, linked: 1, unlinked: 1, expected: "1 synchronisiert, 1 muss eingerichtet werden")
    assert_sync_status(:de, total: 3, linked: 1, unlinked: 2, expected: "1 synchronisiert, 2 müssen eingerichtet werden")
  end

  test "sync status summary covers every English count branch" do
    assert_sync_status(:en, total: 0, linked: 0, unlinked: 0, expected: "No accounts found")
    assert_sync_status(:en, total: 1, linked: 1, unlinked: 0, expected: "1 account synced")
    assert_sync_status(:en, total: 2, linked: 2, unlinked: 0, expected: "2 accounts synced")
    assert_sync_status(:en, total: 2, linked: 1, unlinked: 1, expected: "1 synced, 1 needs setup")
    assert_sync_status(:en, total: 3, linked: 1, unlinked: 2, expected: "1 synced, 2 need setup")
  end

  # base_url decides where the app sends this connection's credentials, so a
  # value pointing anywhere else is refused at save time and ignored at read
  # time. Both layers matter: rows can be written by console or raw SQL.
  test "refuses a base_url that is not the provider's own host" do
    [
      "https://evil.example.com/api/v1",
      "http://169.254.169.254/",
      "https://localhost/api/v1"
    ].each do |value|
      @lunchflow_item.base_url = value

      assert_not @lunchflow_item.valid?, "#{value} must be refused"
      assert_includes @lunchflow_item.errors.attribute_names, :base_url
    end
  end

  test "a value that slipped past validation is not used" do
    @lunchflow_item.update_column(:base_url, "https://evil.example.com/api/v1")

    assert_equal LunchflowItem::DEFAULT_BASE_URL, @lunchflow_item.reload.effective_base_url
  end
end

  private
    def assert_sync_status(locale, total:, linked:, unlinked:, expected:)
      @lunchflow_item.stubs(:total_accounts_count).returns(total)
      @lunchflow_item.stubs(:linked_accounts_count).returns(linked)
      @lunchflow_item.stubs(:unlinked_accounts_count).returns(unlinked)

      I18n.with_locale(locale) do
        assert_equal expected, @lunchflow_item.sync_status_summary
      end
    end
