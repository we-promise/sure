require "test_helper"

class Family::SyncCompleteEventTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  fixtures :families, :accounts, :plaid_items

  setup do
    @family = families(:dylan_family)
    clear_enqueued_jobs
  end

  test "broadcast replaces the accounts page's sync controls and schedules the debounced toast" do
    expect_sync_controls(@family).once

    assert_enqueued_with(job: FamilySyncToastJob, args: ->(args) { args.first == @family.id }) do
      Family::SyncCompleteEvent.new(@family).broadcast
    end
  end

  test "does not broadcast the toast directly" do
    expect_sync_controls(@family).once
    @family.expects(:broadcast_replace_to).with(anything, has_entry(target: "sync-toast")).never

    Family::SyncCompleteEvent.new(@family).broadcast
  end

  test "schedules the toast only after the surrounding transaction commits" do
    expect_sync_controls(@family).once

    ActiveRecord::Base.transaction(requires_new: true) do
      Family::SyncCompleteEvent.new(@family).broadcast
      assert_no_enqueued_jobs only: FamilySyncToastJob
    end

    assert_enqueued_jobs 1, only: FamilySyncToastJob
  end

  private
    def expect_sync_controls(family)
      family.expects(:broadcast_replace_to).with(
        family,
        target: "accounts-sync-controls",
        partial: "accounts/sync_controls",
        locals: { family: family }
      )
    end
end
