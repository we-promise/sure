require "test_helper"

class SyncSchedulesHelperTest < ActionView::TestCase
  class RecordingMenu
    attr_reader :items

    def initialize
      @items = []
    end

    def with_item(**options)
      @items << options
    end
  end

  setup do
    @menu = RecordingMenu.new
  end

  teardown { Current.session = nil }

  test "offers the entry to a viewer who may edit the schedule" do
    Current.session = users(:family_admin).sessions.create!

    sync_schedule_menu_item(@menu, redbark_items(:one))

    assert_equal [ edit_sync_schedule_path(syncable_type: "RedbarkItem", syncable_id: redbark_items(:one).id) ], @menu.items.map { |item| item[:href] }
  end

  # Redbark's and Sophtron's cards show their menu to members, whom the
  # editor would turn away.
  test "leaves the entry out for a member the editor would turn away" do
    Current.session = users(:family_member).sessions.create!

    sync_schedule_menu_item(@menu, redbark_items(:one))

    assert_empty @menu.items
  end

  test "leaves the entry out for a connection being deleted" do
    Current.session = users(:family_admin).sessions.create!
    redbark_items(:one).update_column(:scheduled_for_deletion, true)

    sync_schedule_menu_item(@menu, redbark_items(:one))

    assert_empty @menu.items
  end
end
