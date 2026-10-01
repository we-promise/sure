# frozen_string_literal: true

require "test_helper"

class MercuryItem::SyncerTest < ActiveSupport::TestCase
  test "a rejected token fails the sync and flags the connection" do
    mercury_item = mercury_items(:one)
    Provider::Mercury.any_instance.stubs(:get_accounts)
                     .raises(Provider::Mercury::MercuryError.new("Invalid API token", :unauthorized))
    sync = Sync.create!(syncable: mercury_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal "Invalid API token", sync.error
    assert mercury_item.reload.requires_update?
  end
end
