require "test_helper"

class SyncSchedulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @item = plaid_items(:one)
    @target = { syncable_type: "PlaidItem", syncable_id: @item.id }
  end

  test "the accounts page offers the schedule from a connection's menu" do
    get accounts_url

    assert_response :ok
    assert_select "a[href=?]", edit_sync_schedule_path(@target), text: I18n.t("sync_schedules.menu_item")
  end

  test "edit shows the interval choices with no schedule as the default" do
    get edit_sync_schedule_url(@target)

    assert_response :ok
    assert_select "turbo-frame#modal form[action=?]", sync_schedule_path(@target) do
      # DS::Button renders type="button" unless told otherwise, which submits nothing.
      assert_select "button[type=submit]", text: I18n.t("sync_schedules.edit.save")
    end
    assert_select "select[name='sync_schedule[interval_minutes]']" do
      assert_select "option[value='']", text: I18n.t("sync_schedules.edit.no_schedule")
      assert_select "option[value]", count: SyncSchedule::INTERVALS.size + 1
      assert_select "option[selected]", count: 0
    end
  end

  test "edit preselects the current interval" do
    @item.create_sync_schedule!(interval_minutes: 120)

    get edit_sync_schedule_url(@target)

    assert_select "option[selected][value='120']", text: "Every 2 hours"
  end

  test "update creates the schedule" do
    assert_difference "SyncSchedule.count", 1 do
      patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 30 } }
    end

    assert_redirected_to accounts_path
    assert_equal 30, @item.reload.sync_schedule.interval_minutes
  end

  test "update changes the interval of an existing schedule" do
    @item.create_sync_schedule!(interval_minutes: 30)

    assert_no_difference "SyncSchedule.count" do
      patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 240 } }
    end

    assert_equal 240, @item.reload.sync_schedule.interval_minutes
  end

  test "update with no interval removes the schedule" do
    @item.create_sync_schedule!(interval_minutes: 30)

    patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: "" } }

    assert_redirected_to accounts_path
    assert_nil @item.reload.sync_schedule
  end

  test "update rejects an interval that is not offered" do
    patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 45 } }

    assert_response :unprocessable_entity
    assert_nil @item.reload.sync_schedule
  end

  test "a rejected interval is reported and the saved one stays selected" do
    @item.create_sync_schedule!(interval_minutes: 120)

    patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 45 } }

    assert_response :unprocessable_entity
    assert_select "p.text-destructive", text: /Interval minutes/
    assert_select "option[selected][value='120']"
    assert_equal 120, @item.reload.sync_schedule.interval_minutes
  end

  test "update without the interval field changes nothing" do
    @item.create_sync_schedule!(interval_minutes: 30)

    patch sync_schedule_url(@target), params: { sync_schedule: { other: "x" } }

    assert_response :unprocessable_entity
    assert_equal 30, @item.reload.sync_schedule.interval_minutes
  end

  test "a connection being deleted is not found" do
    @item.update_column(:scheduled_for_deletion, true)

    get edit_sync_schedule_url(@target)

    assert_response :not_found
  end

  test "a member who does not own the connection is turned away" do
    sign_in users(:family_member)

    patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 30 } }

    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
    assert_nil @item.reload.sync_schedule
  end

  # Plaid is a per-connection credential, so a member may manage their own.
  test "a member may schedule a connection they own" do
    member = users(:family_member)
    @item.update!(owner: member)
    sign_in member

    patch sync_schedule_url(@target), params: { sync_schedule: { interval_minutes: 30 } }

    assert_redirected_to accounts_path
    assert_equal 30, @item.reload.sync_schedule.interval_minutes
  end

  test "a connection of another family is not found" do
    other = PlaidItem.create!(family: families(:empty), plaid_id: "item_other", access_token: "token", name: "Elsewhere")

    get edit_sync_schedule_url(syncable_type: "PlaidItem", syncable_id: other.id)

    assert_response :not_found
  end

  test "a type that is not a provider connection is not found" do
    get edit_sync_schedule_url(syncable_type: "Account", syncable_id: accounts(:depository).id)

    assert_response :not_found
  end
end
