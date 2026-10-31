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
end
