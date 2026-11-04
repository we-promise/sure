# frozen_string_literal: true

require "test_helper"

class WiseItem::SyncerTest < ActiveSupport::TestCase
  test "a rejected token fails the sync and flags the connection" do
    wise_item = wise_items(:one)
    Provider::Wise.any_instance.stubs(:get_balances)
                  .raises(Provider::Wise::WiseError.new("Invalid API token", :unauthorized))
    sync = Sync.create!(syncable: wise_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("wise_items.syncer.credentials_invalid"), sync.error
    assert wise_item.reload.requires_update?
  end
end
