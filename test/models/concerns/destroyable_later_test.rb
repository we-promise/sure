require "test_helper"

class DestroyableLaterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @item = plaid_items(:one)
  end

  test "flags the item and enqueues its destruction" do
    assert_enqueued_with(job: DestroyJob, args: [ @item ]) do
      assert @item.destroy_later
    end

    assert @item.reload.scheduled_for_deletion?
    assert_not_includes PlaidItem.syncable, @item
  end

  # The adapter is stubbed rather than perform_later, so ActiveJob's own
  # enqueue path decides what destroy_later sees. This is what an unreachable
  # Redis looks like through the Sidekiq adapter: the push raises straight out.
  test "restores the flag and re-raises when the enqueue raises" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { @item.destroy_later }

    assert_not @item.reload.scheduled_for_deletion?
    assert_includes PlaidItem.syncable, @item
  end

  # An adapter raising ActiveJob::EnqueueError (or an enqueue callback aborting)
  # makes perform_later return false instead of raising.
  test "restores the flag when the enqueue is rejected" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")

    assert_equal false, @item.destroy_later

    assert_not @item.reload.scheduled_for_deletion?
  end

  # QuestradeItem only requires a refresh token while not scheduled for
  # deletion, so a restore that re-ran validations would raise RecordInvalid
  # here, masking the enqueue error and leaving the flag set.
  test "restores the flag without re-running validations that depend on it" do
    item = questrade_items(:one)
    item.update_column(:refresh_token, nil)
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { item.destroy_later }

    assert_not item.reload.scheduled_for_deletion?
  end

  # Every table with the flag gets its destroy_later from here, so a new provider
  # (or a local override) can't reintroduce the unguarded version.
  test "every model with a scheduled_for_deletion column uses the concern" do
    connection = ActiveRecord::Base.connection
    models = connection.tables
      .select { |table| connection.column_exists?(table, :scheduled_for_deletion) }
      .map { |table| table.classify.constantize }

    assert_operator models.size, :>=, 24

    models.each do |model|
      assert_equal DestroyableLater, model.instance_method(:destroy_later).owner,
        "#{model.name}#destroy_later must come from DestroyableLater"
    end
  end
end
