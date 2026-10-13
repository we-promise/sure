require "test_helper"

class FamilySyncToastJobTest < ActiveJob::TestCase
  fixtures :families, :accounts, :plaid_items

  setup do
    @family = families(:dylan_family)
    Sync.where(status: %w[pending syncing]).update_all(status: "completed")
  end

  test "sends the toast when no sync is running" do
    Family.any_instance.expects(:broadcast_replace_to).with(
      @family, target: "sync-toast", partial: "shared/notifications/sync_toast"
    ).once

    FamilySyncToastJob.perform_now(@family.id, Time.current.to_f)
  end

  test "reschedules itself while another sync of the family is still running" do
    plaid_items(:one).syncs.create!(status: "syncing")
    Family.any_instance.expects(:broadcast_replace_to).never
    scheduled_at = Time.current.to_f

    assert_enqueued_with(job: FamilySyncToastJob, args: [ @family.id, scheduled_at, 1 ]) do
      FamilySyncToastJob.perform_now(@family.id, scheduled_at)
    end
  end

  test "stops rechecking after the safety limit and sends the toast" do
    plaid_items(:one).syncs.create!(status: "syncing")
    Family.any_instance.expects(:broadcast_replace_to).once

    assert_no_enqueued_jobs do
      FamilySyncToastJob.perform_now(@family.id, Time.current.to_f, FamilySyncToastJob::MAX_RECHECKS)
    end
  end

  test "is superseded by a newer scheduled run" do
    scheduled_at = Time.current.to_f
    Rails.cache.stubs(:read).with(FamilySyncToastJob.cache_key(@family.id)).returns(scheduled_at + 5)
    Family.any_instance.expects(:broadcast_replace_to).never

    assert_no_enqueued_jobs do
      FamilySyncToastJob.perform_now(@family.id, scheduled_at)
    end
  end

  test "ignores other families, cancelled syncs and syncs hung past the visibility window" do
    other = accounts(:depository).dup.tap do |account|
      account.family = families(:empty)
      account.save!(validate: false)
    end
    other.syncs.create!(status: "syncing")
    plaid_items(:one).syncs.create!(status: "syncing", cancel_requested_at: Time.current)
    plaid_items(:one).syncs.create!(status: "syncing", created_at: (Sync::VISIBLE_FOR + 1.minute).ago)

    Family.any_instance.expects(:broadcast_replace_to).with(
      @family, target: "sync-toast", partial: "shared/notifications/sync_toast"
    ).once

    FamilySyncToastJob.perform_now(@family.id, Time.current.to_f)
  end

  test "a crashed sync delays the toast at most until it leaves the visibility window" do
    crashed = plaid_items(:one).syncs.create!(status: "syncing")

    Family.any_instance.expects(:broadcast_replace_to).never
    FamilySyncToastJob.perform_now(@family.id, Time.current.to_f)

    travel_to (Sync::VISIBLE_FOR + 1.minute).from_now do
      Family.any_instance.expects(:broadcast_replace_to).with(
        @family, target: "sync-toast", partial: "shared/notifications/sync_toast"
      ).once
      FamilySyncToastJob.perform_now(@family.id, Time.current.to_f)
    end
    assert crashed.reload.syncing?
  end

  test "does nothing when the family no longer exists" do
    Family.any_instance.expects(:broadcast_replace_to).never

    assert_nothing_raised { FamilySyncToastJob.perform_now(SecureRandom.uuid, Time.current.to_f) }
  end

  test "schedule_for enqueues a delayed run" do
    assert_enqueued_with(job: FamilySyncToastJob, args: ->(args) { args.first == @family.id }) do
      FamilySyncToastJob.schedule_for(@family)
    end
  end
end
