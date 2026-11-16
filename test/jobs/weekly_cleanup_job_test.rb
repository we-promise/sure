require "test_helper"

class WeeklyCleanupJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => true))
  end

  test "creates one proactive chat per admin, not for members" do
    assert_difference -> { @admin.chats.count }, 1 do
      assert_no_difference -> { @member.chats.count } do
        WeeklyCleanupJob.perform_now(family_id: @family.id)
      end
    end

    chat = @admin.chats.ordered.first
    assert_equal 1, chat.messages.count
    message = chat.messages.first
    assert_instance_of AssistantMessage, message
    assert message.complete?
    assert_includes message.content, "cleanup"
  end

  test "is idempotent: rerunning does not respawn chats" do
    WeeklyCleanupJob.perform_now(family_id: @family.id)

    assert_no_difference -> { Chat.count } do
      WeeklyCleanupJob.perform_now(family_id: @family.id)
    end

    assert_equal 1, WeeklyCleanupRun.where(family: @family, user: @admin).count
  end

  test "skips families without preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    assert_no_difference -> { Chat.count } do
      WeeklyCleanupJob.perform_now(family_id: @family.id)
    end
  end

  test "fan-out enqueues only for preview-enabled families" do
    assert_enqueued_with(job: WeeklyCleanupJob, args: [ { family_id: @family.id } ]) do
      WeeklyCleanupJob.perform_now
    end
  end

  test "findings omit accounts the admin cannot access" do
    other = users(:family_member)
    hidden = Account.create!(
      family: @family, owner: other, name: "Hidden Member Account", balance: 0, currency: "USD",
      accountable: Depository.new
    )
    entry = hidden.entries.create!(
      name: "Secret Merchant", date: 1.day.ago.to_date, amount: 42, currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )
    assert_not @admin.accessible_accounts.exists?(hidden.id)

    WeeklyCleanupJob.perform_now(family_id: @family.id)

    content = @admin.chats.ordered.first.messages.first.content
    assert_not_includes content, entry.name
    assert_not_includes content, hidden.name
  end

  test "skips deactivated admins and admins with AI turned off" do
    @admin.update_columns(ai_enabled: false)

    assert_no_difference -> { Chat.count } do
      WeeklyCleanupJob.perform_now(family_id: @family.id)
    end
  end

  test "dates the weekly period by the family's local date" do
    @family.update!(timezone: "Pacific/Kiritimati")
    travel_to Time.utc(2026, 11, 22, 12, 0) do # Sunday UTC, Monday in UTC+14
      WeeklyCleanupJob.perform_now(family_id: @family.id)
    end

    assert_equal Date.new(2026, 11, 23), WeeklyCleanupRun.find_by!(family: @family, user: @admin).period_start
  end

  test "cleanup run foreign keys cascade so family and user deletes don't raise" do
    foreign_keys = ActiveRecord::Base.connection.foreign_keys("weekly_cleanup_runs")

    assert_equal %w[families users], foreign_keys.map(&:to_table).sort
    assert(foreign_keys.all? { |fk| fk.on_delete == :cascade })
  end
end
