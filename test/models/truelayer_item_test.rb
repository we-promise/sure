require "test_helper"

class TruelayerItemTest < ActiveSupport::TestCase
  setup do
    @item = TruelayerItem.create!(
      family: families(:empty), name: "Acme Bank", client_id: "sure-test", client_secret: "secret",
      access_token: "old-access", refresh_token: "old-refresh", access_token_expires_at: 1.minute.from_now
    )
  end

  test "refreshes an expiring token and keeps the rotated refresh token" do
    Provider::Truelayer.any_instance.expects(:refresh_access_token).with("old-refresh")
      .returns(access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600)

    used = nil
    @item.with_access_token { |fresh| used = fresh.call }

    assert_equal "new-access", used
    @item.reload
    assert_equal "new-refresh", @item.refresh_token
    assert_in_delta 1.hour.from_now, @item.access_token_expires_at, 5.seconds
  end

  test "keeps the refresh token when TrueLayer doesn't rotate it" do
    Provider::Truelayer.any_instance.expects(:refresh_access_token).returns(access_token: "new-access", refresh_token: nil, expires_in: 3600)

    @item.with_access_token { |fresh| fresh.call }

    assert_equal "old-refresh", @item.reload.refresh_token
  end

  test "uses a valid token without refreshing" do
    @item.update!(access_token_expires_at: 30.minutes.from_now)
    Provider::Truelayer.any_instance.expects(:refresh_access_token).never

    @item.with_access_token { |fresh| assert_equal "old-access", fresh.call }
  end

  test "flags the connection for reconnecting when the refresh token is dead" do
    Provider::Truelayer.any_instance.expects(:refresh_access_token)
      .raises(Provider::Truelayer::TruelayerError.new("invalid_grant", :invalid_grant))

    assert_raises(Provider::Truelayer::TruelayerError) { @item.with_access_token { |fresh| fresh.call } }

    assert @item.reload.requires_update?
    assert_equal "invalid_grant", @item.reauth_reason
  end

  test "does not flag the connection for a transient failure" do
    Provider::Truelayer.any_instance.expects(:refresh_access_token)
      .raises(Provider::Truelayer::TruelayerError.new("boom", :server_error))

    assert_raises(Provider::Truelayer::TruelayerError) { @item.with_access_token { |fresh| fresh.call } }

    assert @item.reload.good?
  end

  test "a token a request was refused with is refreshed once, even before it expires" do
    @item.update!(access_token_expires_at: 30.minutes.from_now)
    Provider::Truelayer.any_instance.expects(:refresh_access_token).once.with("old-refresh")
      .returns(access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600)

    assert_equal "new-access", @item.fresh_access_token(rejected: "old-access")
    # Already rotated (by this or another process): no second refresh.
    assert_equal "new-access", @item.fresh_access_token(rejected: "old-access")
  end

  test "using an unconnected item fails without flagging it for reconnecting" do
    @item.update!(access_token: nil, refresh_token: nil)

    error = assert_raises(Provider::Truelayer::TruelayerError) { @item.with_access_token { |fresh| fresh.call } }

    assert_equal :not_connected, error.error_type
    assert @item.reload.good?
  end

  test "completing authorization stores tokens and consent metadata" do
    @item.update!(access_token: nil, refresh_token: nil, name: @item.default_name)
    Provider::Truelayer.any_instance.expects(:exchange_code).with(code: "abc", redirect_uri: "http://x/cb")
      .returns(access_token: "a", refresh_token: "r", expires_in: 3600)
    Provider::Truelayer.any_instance.expects(:get_me).with("a")
      .returns(consent_expires_at: "2030-01-31T12:00:00Z", provider: { provider_id: "ob-acme", display_name: "Acme Bank" })

    @item.complete_authorization!(code: "abc", redirect_uri: "http://x/cb")

    @item.reload
    assert @item.connected?
    assert @item.full_history_available?
    assert_equal "Acme Bank", @item.name
    assert_equal "ob-acme", @item.institution_id
    assert_equal Time.zone.parse("2030-01-31T12:00:00Z"), @item.consent_expires_at
  end

  test "a new consent opens a new history window" do
    @item.update!(last_authorized_at: 100.days.ago, history_backfilled_at: 99.days.ago)
    Provider::Truelayer.any_instance.expects(:exchange_code).returns(access_token: "a", refresh_token: "r", expires_in: 3600)
    Provider::Truelayer.any_instance.expects(:get_me).returns({})

    @item.complete_authorization!(code: "abc", redirect_uri: "http://x/cb")

    @item.reload
    assert_nil @item.history_backfilled_at
    assert @item.full_history_available?
    assert_not @item.history_backfill_missed?
  end

  test "full history is only available for a few minutes after consent" do
    @item.update!(last_authorized_at: 3.minutes.ago)
    assert @item.full_history_available?

    @item.update!(last_authorized_at: 6.minutes.ago)
    assert_not @item.full_history_available?
  end

  test "a missed history backfill is reported only once the consent window has closed" do
    @item.update!(last_authorized_at: 1.minute.ago)
    assert_not @item.history_backfill_missed?

    @item.update!(last_authorized_at: 10.minutes.ago)
    assert @item.history_backfill_missed?

    @item.update!(history_backfilled_at: Time.current)
    assert_not @item.history_backfill_missed?
  end

  test "unconnected items are not syncable" do
    unconnected = TruelayerItem.create!(family: families(:empty), name: "New", client_id: "sure-test", client_secret: "secret")

    assert_includes TruelayerItem.syncable, @item
    assert_not_includes TruelayerItem.syncable, unconnected
  end
end
