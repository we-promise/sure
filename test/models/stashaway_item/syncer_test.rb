require "test_helper"

class StashawayItem::SyncerTest < ActiveSupport::TestCase
  include StashawayTestHelper

  setup do
    @item = stashaway_items(:connected)
    @syncer = StashawayItem::Syncer.new(@item)
  end

  test "an expired token fails the sync and asks for a new sign-in" do
    sync = @item.syncs.create!
    Provider::Stashaway.any_instance.stubs(:goals).raises(Provider::Stashaway::AuthenticationError, "StashAway sign-in has expired (HTTP 401)")

    assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(sync) }

    @item.reload
    assert @item.requires_update?
    assert_nil @item.api_token
    assert_not StashawayItem.syncable.exists?(@item.id)
    assert_equal "auth_error", sync.reload.sync_stats.dig("errors", 0, "category")
  end

  test "a connection that needs a sign-in does not call StashAway" do
    @item.require_reauthentication!
    Provider::Stashaway.any_instance.expects(:goals).never
    Provider::Stashaway.any_instance.expects(:login).never

    assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(@item.syncs.create!) }
  end

  test "a token StashAway stopped accepting is replaced by a sign-in with the saved password" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    sync = @item.syncs.create!
    Provider::Stashaway.any_instance.expects(:goals).twice
      .raises(Provider::Stashaway::AuthenticationError, "StashAway sign-in has expired (HTTP 401)").then.returns([])
    Provider::Stashaway.any_instance.expects(:login).with(email: "investor@example.com", password: "secret", device_id: @item.device_id)
      .returns(Provider::Stashaway::Session.new(token: "new-token", user_id: "sa-user-1"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).with("new-token").returns(true)

    @syncer.perform_sync(sync)

    @item.reload
    assert @item.ready_for_sync?
    assert_equal [ "new-token", "secret" ], [ @item.api_token, @item.password ]
    assert_equal 0, sync.reload.sync_stats["total_errors"]
  end

  test "a sign-in by itself that StashAway answers with a code waits for the code" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    sync = @item.syncs.create!
    Provider::Stashaway.any_instance.stubs(:goals).raises(Provider::Stashaway::AuthenticationError, "StashAway sign-in has expired (HTTP 401)")
    Provider::Stashaway.any_instance.stubs(:login)
      .returns(Provider::Stashaway::Session.new(token: "pre-2fa-token", user_id: "sa-user-1", two_factor_required: true))
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).with(token: "pre-2fa-token").returns(true)

    error = assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(sync) }

    assert_equal I18n.t("stashaway_items.sync.errors.code_required"), error.message
    @item.reload
    assert @item.login_pending?
    assert @item.password_saved?
    assert_nil @item.api_token
    assert_equal "auth_error", sync.reload.sync_stats.dig("errors", 0, "category")
  end

  test "a connection waiting for its code is not signed in again by itself" do
    @item.update!(status: :requires_update, api_token: nil, password: "secret", pending_login_token: "login-token", pending_login_started_at: 1.hour.ago)
    Provider::Stashaway.any_instance.expects(:login).never

    error = assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(@item.syncs.create!) }

    assert_equal I18n.t("stashaway_items.sync.errors.code_required"), error.message
    assert_equal "login-token", @item.reload.pending_login_token
  end

  test "a saved password StashAway refuses is forgotten" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    sync = @item.syncs.create!
    Provider::Stashaway.any_instance.stubs(:goals).raises(Provider::Stashaway::AuthenticationError, "StashAway sign-in has expired (HTTP 401)")
    Provider::Stashaway.any_instance.stubs(:login).raises(Provider::Stashaway::InvalidCredentials, "Incorrect email or password")

    error = assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(sync) }

    assert_match(/refused the saved password \(Incorrect email or password\)/, error.message)
    @item.reload
    assert_nil @item.password
    assert @item.requires_update?
    assert_nil @item.api_token
    assert_equal "auth_error", sync.reload.sync_stats.dig("errors", 0, "category")
  end

  test "a connection without a token signs in with its saved password before importing" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    @item.require_reauthentication!
    Provider::Stashaway.any_instance.expects(:login).with(email: "investor@example.com", password: "secret", device_id: @item.device_id)
      .returns(Provider::Stashaway::Session.new(token: "new-token", user_id: "sa-user-1"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).with("new-token").returns(true)
    Provider::Stashaway.any_instance.expects(:goals).once.returns([])

    @syncer.perform_sync(@item.syncs.create!)

    @item.reload
    assert @item.good?
    assert_equal "new-token", @item.api_token
  end

  test "a sign-in by itself that reaches another StashAway login fails the sync" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    @item.require_reauthentication!
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t", user_id: "sa-user-2"))
    Provider::Stashaway.any_instance.expects(:goals).never

    error = assert_raises(Provider::Stashaway::AuthenticationError) { @syncer.perform_sync(@item.syncs.create!) }

    assert_equal I18n.t("stashaway_items.login.account_mismatch"), error.message
    assert @item.reload.password_saved?
  end

  test "flags discovered portfolios for setup while they are unlinked" do
    StashawayItem::Importer.any_instance.expects(:import).returns({ success: true })
    StashawayItem.any_instance.expects(:process_accounts).never

    @syncer.perform_sync(@item.syncs.create!)

    assert @item.reload.pending_account_setup?
  end

  test "processes linked accounts and lists the rows their plans left to the returns adjustment" do
    stashaway_accounts(:general).link_to!(accounts(:investment))
    StashawayItem::Importer.any_instance.expects(:import).returns({ success: true })
    StashawayItem.any_instance.expects(:process_accounts).returns([
      { success: true, result: StashawayAccount::Processor::Result.new(entries: 3, pending: 0, warnings: [ "General: no USD→SGD rate" ]) }
    ])
    sync = @item.syncs.create!

    @syncer.perform_sync(sync)

    assert_not @item.reload.pending_account_setup?
    assert_equal 1, sync.reload.sync_stats["data_warnings"]
    assert_equal "General: no USD→SGD rate", sync.sync_stats.dig("data_quality_details", 0, "message")
  end
end
