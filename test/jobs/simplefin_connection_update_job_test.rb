require "test_helper"

class SimplefinConnectionUpdateJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "Reconnect Test", access_url: "https://example.com/access")
  end

  test "a rejected setup token is discarded and logged for support" do
    SimplefinItem.any_instance.expects(:update_access_url!)
      .raises(Provider::Simplefin::SimplefinError.new("SimpleFIN URL points to a disallowed network address", :invalid_url))

    assert_difference -> { DebugLogEntry.where(provider_key: "simplefin", family: @family).count }, 1 do
      SimplefinConnectionUpdateJob.perform_now(family_id: @family.id, old_simplefin_item_id: @item.id, setup_token: "token")
    end

    entry = DebugLogEntry.where(provider_key: "simplefin").order(:created_at).last
    assert_equal "invalid_url", entry.metadata["error_type"]
    assert_not_includes entry.message, "token"
  end
end
