require "test_helper"

class SyncTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "does not run if not in a valid state" do
    syncable = accounts(:depository)
    sync = Sync.create!(syncable: syncable, status: :completed)

    syncable.expects(:perform_sync).never

    sync.perform

    assert_equal "completed", sync.status
  end

  test "runs successful sync" do
    syncable = accounts(:depository)
    sync = Sync.create!(syncable: syncable)

    syncable.expects(:perform_sync).with(sync).once

    assert_equal "pending", sync.status

    sync.perform

    assert sync.completed_at < Time.now
    assert_equal "completed", sync.status
  end

  test "handles sync errors" do
    syncable = accounts(:depository)
    sync = Sync.create!(syncable: syncable)

    syncable.expects(:perform_sync).with(sync).raises(StandardError.new("test sync error"))

    assert_equal "pending", sync.status

    sync.perform

    assert sync.failed_at < Time.now
    assert_equal "failed", sync.status
    assert_equal "test sync error", sync.error
  end

  test "can run nested syncs that alert the parent when complete" do
    family = families(:dylan_family)
    plaid_item = plaid_items(:one)
    account = accounts(:connected)

    family_sync = Sync.create!(syncable: family)
    plaid_item_sync = Sync.create!(syncable: plaid_item, parent: family_sync)
    account_sync = Sync.create!(syncable: account, parent: plaid_item_sync)

    assert_equal "pending", family_sync.status
    assert_equal "pending", plaid_item_sync.status
    assert_equal "pending", account_sync.status

    family.expects(:perform_sync).with(family_sync).once

    family_sync.perform

    assert_equal "syncing", family_sync.reload.status

    plaid_item.expects(:perform_sync).with(plaid_item_sync).once

    plaid_item_sync.perform

    assert_equal "syncing", family_sync.reload.status
    assert_equal "syncing", plaid_item_sync.reload.status

    account.expects(:perform_sync).with(account_sync).once

    # Since these are accessed through `parent`, they won't necessarily be the same
    # instance we configured above
    Account.any_instance.expects(:perform_post_sync).once
    Account.any_instance.expects(:broadcast_sync_complete).once
    PlaidItem.any_instance.expects(:perform_post_sync).once
    PlaidItem.any_instance.expects(:broadcast_sync_complete).once
    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    account_sync.perform

    assert_equal "completed", plaid_item_sync.reload.status
    assert_equal "completed", account_sync.reload.status
    assert_equal "completed", family_sync.reload.status
  end

  test "failures propagate up the chain" do
    family = families(:dylan_family)
    plaid_item = plaid_items(:one)
    account = accounts(:connected)

    family_sync = Sync.create!(syncable: family)
    plaid_item_sync = Sync.create!(syncable: plaid_item, parent: family_sync)
    account_sync = Sync.create!(syncable: account, parent: plaid_item_sync)

    assert_equal "pending", family_sync.status
    assert_equal "pending", plaid_item_sync.status
    assert_equal "pending", account_sync.status

    family.expects(:perform_sync).with(family_sync).once

    family_sync.perform

    assert_equal "syncing", family_sync.reload.status

    plaid_item.expects(:perform_sync).with(plaid_item_sync).once

    plaid_item_sync.perform

    assert_equal "syncing", family_sync.reload.status
    assert_equal "syncing", plaid_item_sync.reload.status

    # This error should "bubble up" to the PlaidItem and Family sync results
    account.expects(:perform_sync).with(account_sync).raises(StandardError.new("test account sync error"))

    # Since these are accessed through `parent`, they won't necessarily be the same
    # instance we configured above
    Account.any_instance.expects(:perform_post_sync).once
    PlaidItem.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:perform_post_sync).once

    Account.any_instance.expects(:broadcast_sync_complete).once
    PlaidItem.any_instance.expects(:broadcast_sync_complete).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    account_sync.perform

    assert_equal "failed", plaid_item_sync.reload.status
    assert_equal "failed", account_sync.reload.status
    assert_equal "failed", family_sync.reload.status
  end

  test "parent failure should not change status if child succeeds" do
    family = families(:dylan_family)
    plaid_item = plaid_items(:one)
    account = accounts(:connected)

    family_sync = Sync.create!(syncable: family)
    plaid_item_sync = Sync.create!(syncable: plaid_item, parent: family_sync)
    account_sync = Sync.create!(syncable: account, parent: plaid_item_sync)

    assert_equal "pending", family_sync.status
    assert_equal "pending", plaid_item_sync.status
    assert_equal "pending", account_sync.status

    family.expects(:perform_sync).with(family_sync).raises(StandardError.new("test family sync error"))

    family_sync.perform

    assert_equal "failed", family_sync.reload.status

    plaid_item.expects(:perform_sync).with(plaid_item_sync).raises(StandardError.new("test plaid item sync error"))

    plaid_item_sync.perform

    assert_equal "failed", family_sync.reload.status
    assert_equal "failed", plaid_item_sync.reload.status

    # Leaf level sync succeeds, but shouldn't change the status of the already-failed parent syncs
    account.expects(:perform_sync).with(account_sync).once

    # Since these are accessed through `parent`, they won't necessarily be the same
    # instance we configured above
    Account.any_instance.expects(:perform_post_sync).once
    PlaidItem.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:perform_post_sync).once

    Account.any_instance.expects(:broadcast_sync_complete).once
    PlaidItem.any_instance.expects(:broadcast_sync_complete).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    account_sync.perform

    assert_equal "failed", plaid_item_sync.reload.status
    assert_equal "failed", family_sync.reload.status
    assert_equal "completed", account_sync.reload.status
  end

  test "sync staled mid-run does not run post-sync when its job finishes" do
    syncable = accounts(:depository)
    sync = Sync.create!(syncable: syncable)

    # Simulate SyncCleanerJob marking the sync stale while the job is still running
    syncable.expects(:perform_sync).with { |s| Sync.find(s.id).mark_stale!; true }

    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never

    sync.perform

    assert_equal "stale", sync.reload.status
  end

  test "sync staled mid-run does not raise when its job fails" do
    syncable = accounts(:depository)
    sync = Sync.create!(syncable: syncable)

    syncable.expects(:perform_sync).with { |s| Sync.find(s.id).mark_stale!; true }
      .raises(StandardError.new("provider blew up"))

    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never

    assert_nothing_raised do
      sync.perform
    end

    assert_equal "stale", sync.reload.status
    assert_equal "provider blew up", sync.error
  end

  test "request_cancel! resolves a pending sync immediately" do
    sync = Sync.create!(syncable: accounts(:depository))

    assert sync.request_cancel!
    assert_equal "stale", sync.reload.status

    # The queued job later no-ops via the may_start? guard
    accounts(:depository).expects(:perform_sync).never
    sync.perform
    assert_equal "stale", sync.reload.status
  end

  test "cancelling a pending child finalizes its waiting parent" do
    family = families(:dylan_family)
    parent = Sync.create!(syncable: family, status: :syncing)
    child = Sync.create!(syncable: accounts(:depository), parent: parent, status: :pending)

    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    assert child.request_cancel!

    # The child's queued job will no-op via may_start?, so nothing else ever
    # finalizes the parent — request_cancel! itself must cascade or the
    # parent hangs in syncing until the 24h sweep.
    assert_equal "stale", child.reload.status
    assert_equal "completed", parent.reload.status
  end

  test "a late provider complete! cannot resurrect a cancelled sync" do
    item = SimplefinItem.create!(family: families(:dylan_family), name: "SF Conn", access_url: "https://example.com/access")
    sync = Sync.create!(syncable: item, status: :syncing)

    # Simulates the Sidekiq job's in-memory copy, loaded before cancellation
    in_job_copy = Sync.find(sync.id)

    assert sync.request_cancel!
    assert_equal "stale", sync.reload.status

    SimplefinItem::Syncer.new(item).send(:mark_completed, in_job_copy)

    assert_equal "stale", sync.reload.status
  end

  test "request_cancel! returns false for terminal syncs" do
    sync = Sync.create!(syncable: accounts(:depository), status: :completed)

    assert_not sync.request_cancel!
    assert_equal "completed", sync.reload.status
  end

  test "cancelling a running tree stales pending children and resolves the root to stale without post-sync" do
    family = families(:dylan_family)
    plaid_item = plaid_items(:one)
    account = accounts(:connected)

    family_sync = Sync.create!(syncable: family, status: :syncing)
    running_child = Sync.create!(syncable: plaid_item, parent: family_sync)
    pending_child = Sync.create!(syncable: account, parent: running_child, status: :pending)

    running_child.start!

    assert family_sync.request_cancel!

    # Pending descendants are resolved immediately; running ones are left alone
    assert_equal "stale", pending_child.reload.status
    assert_equal "syncing", running_child.reload.status
    assert_equal "syncing", family_sync.reload.status

    # The running child finishes honestly; the cancelled root resolves to
    # stale and must not re-run family transfer matching / rules / broadcasts
    PlaidItem.any_instance.expects(:perform_post_sync).once
    PlaidItem.any_instance.expects(:broadcast_sync_complete).once
    Family.any_instance.expects(:perform_post_sync).never
    Family.any_instance.expects(:broadcast_sync_complete).never

    # Simulate the in-flight job finishing after the cancel was requested
    running_child.finalize_if_all_children_finalized

    assert_equal "completed", running_child.reload.status
    assert_equal "stale", family_sync.reload.status
  end

  test "cancel-requested syncs are not visible and do not swallow new sync requests" do
    account = accounts(:depository)
    Sync.where(syncable: account).destroy_all

    sync = Sync.create!(syncable: account, status: :syncing, cancel_requested_at: Time.current)

    assert_not account.syncing?

    new_sync = nil
    assert_difference "Sync.count", 1 do
      new_sync = account.sync_later
    end
    assert_not_equal sync.id, new_sync.id
  end

  test "family syncer stops scheduling children once cancel is requested" do
    family = families(:dylan_family)
    sync = Sync.create!(syncable: family, status: :syncing, cancel_requested_at: Time.current)

    assert_no_difference "Sync.count" do
      Family::Syncer.new(family).perform_sync(sync)
    end
  end

  test "clean marks stale incomplete rows" do
    stale_pending = Sync.create!(
      syncable: accounts(:depository),
      status: :pending,
      created_at: 25.hours.ago
    )

    stale_syncing = Sync.create!(
      syncable: accounts(:depository),
      status: :syncing,
      created_at: 25.hours.ago,
      pending_at: 24.hours.ago,
      syncing_at: 23.hours.ago
    )

    Sync.clean

    assert_equal "stale", stale_pending.reload.status
    assert_equal "stale", stale_syncing.reload.status
  end

  test "ordered uses id as deterministic tie breaker" do
    timestamp = Time.current.change(usec: 0)
    older_id = SecureRandom.uuid
    newer_id = SecureRandom.uuid
    older_id, newer_id = [ older_id, newer_id ].sort

    older_sync = Sync.create!(id: older_id, syncable: accounts(:depository), status: :completed, created_at: timestamp)
    newer_sync = Sync.create!(id: newer_id, syncable: accounts(:connected), status: :completed, created_at: timestamp)

    ordered_ids = Sync.where(id: [ older_sync.id, newer_sync.id ]).ordered.pluck(:id)

    assert_equal [ newer_sync.id, older_sync.id ], ordered_ids
  end

  test "for_family includes syncable provider item associations from family reflections" do
    family = families(:dylan_family)
    syncable_item_associations = Family.reflect_on_all_associations(:has_many).select do |association|
      association.name.to_s.end_with?("_items") &&
        association.klass.included_modules.include?(Syncable)
    rescue NameError
      false
    end

    syncs = syncable_item_associations.filter_map do |association|
      syncable = family.public_send(association.name).first
      next unless syncable

      Sync.create!(syncable: syncable, status: :completed)
    end

    assert syncs.any?, "Expected syncable provider item fixtures for this family"
    assert_equal syncs.map(&:id).sort, Sync.for_family(family).where(id: syncs.map(&:id)).pluck(:id).sort
  end

  test "any_incomplete_for? fires on a Sync against any Syncable provider item association" do
    family = families(:dylan_family)
    Sync.for_family(family).incomplete.find_each(&:destroy)
    assert_not Sync.any_incomplete_for?(family)

    mercury_item = mercury_items(:one)
    incomplete = Sync.create!(syncable: mercury_item, status: :pending)
    assert Sync.any_incomplete_for?(family),
           "any_incomplete_for? should report true for an in-flight Mercury sync"

    incomplete.update!(status: :completed)
    assert_not Sync.any_incomplete_for?(family)
  end

  test "any_incomplete_for? fires on a Sync against the family itself" do
    family = families(:dylan_family)
    Sync.for_family(family).incomplete.find_each(&:destroy)
    assert_not Sync.any_incomplete_for?(family)

    Sync.create!(syncable: family, status: :syncing)
    assert Sync.any_incomplete_for?(family)
  end

  test "api error payload is present for failed syncs without raw error text" do
    sync = Sync.create!(syncable: accounts(:depository), status: :failed)

    assert_equal({ message: "Sync failed" }, sync.api_error_payload)
  end

  test "expand_window_if_needed widens start and end dates on a pending sync" do
    initial_start = 1.day.ago.to_date
    initial_end   = 1.day.ago.to_date

    sync = Sync.create!(
      syncable: accounts(:depository),
      window_start_date: initial_start,
      window_end_date: initial_end
    )

    new_start = 5.days.ago.to_date
    new_end   = Date.current

    sync.expand_window_if_needed(new_start, new_end)
    sync.reload

    assert_equal new_start, sync.window_start_date
    assert_equal new_end,   sync.window_end_date
  end
end
