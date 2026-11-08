require "test_helper"

class GocardlessItemTest < ActiveSupport::TestCase
  test "family sync skips credential-only items until consent is created" do
    item = families(:empty).gocardless_items.create!(name: "Test bank", secret_id: "test-id", secret_key: "test-key")
    assert_not GocardlessItem.syncable.exists?(item.id)
    item.update!(requisition_id: "test-requisition")
    assert GocardlessItem.syncable.exists?(item.id)
    item.update!(scheduled_for_deletion: true)
    assert_not GocardlessItem.syncable.exists?(item.id)
  end
end
