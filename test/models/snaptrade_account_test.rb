require "test_helper"

class SnaptradeAccountTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = SnaptradeItem.create!(
      family: @family_a,
      name: "Family A Broker",
      client_id: "client_a",
      consumer_key: "key_a",
      status: "good"
    )

    @item_b = SnaptradeItem.create!(
      family: @family_b,
      name: "Family B Broker",
      client_id: "client_b",
      consumer_key: "key_b",
      status: "good"
    )
  end

  test "same snaptrade_account_id can be linked under different snaptrade_items" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "shared_snap_uuid_1",
      name: "IRA",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "SnaptradeAccount.count", 1 do
      SnaptradeAccount.create!(
        snaptrade_item: @item_b,
        snaptrade_account_id: "shared_snap_uuid_1",
        name: "IRA",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same snaptrade_account_id cannot appear twice under the same snaptrade_item" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = SnaptradeAccount.new(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:snaptrade_account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      SnaptradeAccount.create!(
        snaptrade_item: @item_a,
        snaptrade_account_id: "dup_snap_uuid",
        name: "Brokerage",
        currency: "USD",
        current_balance: 1000
      )
    end
  end

  # Regression: the after_destroy callback enqueues SnaptradeConnectionCleanupJob,
  # which references the account/item by id. If it is enqueued before the destroy
  # transaction commits (Rails 8.1's immediate-enqueue default), a worker can run
  # before COMMIT: its "do other accounts still share this authorization?" guard
  # then sees the not-yet-deleted row, skips the provider call, and leaks the
  # SnapTrade connection. Enqueuing must be deferred until commit.
  test "connection cleanup job is deferred until the destroy transaction commits" do
    account = SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "cleanup_uuid",
      snaptrade_authorization_id: "auth_cleanup",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      account.destroy!
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == SnaptradeConnectionCleanupJob }
    end

    assert_not enqueued_mid_transaction,
      "SnaptradeConnectionCleanupJob was enqueued before the destroy committed (would race COMMIT and leak the provider connection)"
    assert_enqueued_with job: SnaptradeConnectionCleanupJob
  end
end
