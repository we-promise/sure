# frozen_string_literal: true

require "test_helper"

class CoinspotItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = CoinspotItem.create!(
      family: @family,
      name: "My CoinSpot",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  # `active` excludes a flagged row, so a flag that survives a failed enqueue
  # hides the connection from the UI with no job coming to delete it, and no
  # way for the user to retry. DestroyJob's own rescue only covers a failure
  # once the job is running -- this is the other side of that window.
  test "destroy_later restores the flag when enqueueing raises" do
    DestroyJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_raises(StandardError) { @item.destroy_later }

    assert_not @item.reload.scheduled_for_deletion?
  end

  test "destroy_later restores the flag when enqueueing returns false" do
    DestroyJob.stubs(:perform_later).returns(false)

    @item.destroy_later

    assert_not @item.reload.scheduled_for_deletion?
  end

  test "destroy_later keeps the flag when the job is enqueued" do
    DestroyJob.stubs(:perform_later).returns(true)

    @item.destroy_later

    assert @item.reload.scheduled_for_deletion?
  end

  test "next_nonce! is monotonic even when the clock does not advance" do
    first = @item.next_nonce!
    second = @item.next_nonce!

    assert_operator Integer(second), :>, Integer(first)
  end
end
