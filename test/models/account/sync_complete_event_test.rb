require "test_helper"
require "turbo/broadcastable/test_helper"

class Account::SyncCompleteEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @account = accounts(:depository)
    @account.update!(name: "Private Savings Row Marker")
    Current.reset
  end

  # The row carries the account's name and balance, and every family member
  # subscribes to the family stream, including members the account is not
  # shared with.
  test "an account sync does not broadcast the rendered row to the family" do
    streams = capture_turbo_stream_broadcasts(@account.family) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end

    assert_not_includes streams.map { |stream| stream["target"] }, "account_#{@account.id}"
    streams.each { |stream| assert_not_includes stream.to_html, @account.name }
  end

  # A linked account can sync on its own, with no provider event after it, so
  # the toast is what refreshes /accounts for each viewer.
  test "a linked account syncing alone still sends the family toast" do
    @account.stubs(:linked?).returns(true)

    targets = capture_turbo_stream_broadcasts(@account.family) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "sync-toast"
  end

  test "an unlinked account still sends the family toast" do
    @account.stubs(:linked?).returns(false)

    targets = capture_turbo_stream_broadcasts(@account.family) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "sync-toast"
  end

  test "the account page still refreshes on its own stream" do
    actions = capture_turbo_stream_broadcasts(@account) do
      Account::SyncCompleteEvent.new(@account).broadcast
    end.map { |stream| stream["action"] }

    assert_includes actions, "refresh"
  end
end
