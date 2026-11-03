require "test_helper"

class MoomooItemTest < ActiveSupport::TestCase
  CALLBACK_URL = "http://www.example.com/moomoo_items/callback".freeze

  setup do
    @family = families(:empty)
    @item = @family.moomoo_items.create!(
      name: "moomoo",
      oauth_client_id: "client-1",
      oauth_redirect_uri: CALLBACK_URL,
      access_token: "old",
      refresh_token: "r",
      access_token_expires_at: 1.minute.from_now
    )
  end

  test "an access token about to expire is refreshed, keeping the refresh token" do
    Provider::Moomoo.any_instance.expects(:refresh_access_token).with("r")
      .returns(access_token: "new", refresh_token: nil, expires_in: 7200, scope: "trade:read accid:1")

    token = @item.with_access_token { |fresh| fresh.call }

    assert_equal "new", token
    @item.reload
    assert_equal "r", @item.refresh_token
    assert_equal "trade:read accid:1", @item.oauth_scope
    assert_in_delta Time.current, @item.last_token_refresh_at, 5.seconds
    assert @item.access_token_expires_at > 1.hour.from_now
  end

  test "a valid access token is used as it is" do
    @item.update!(access_token_expires_at: 1.hour.from_now)
    Provider::Moomoo.any_instance.expects(:refresh_access_token).never

    assert_equal "old", @item.with_access_token { |fresh| fresh.call }
  end

  test "a token far from expiring is used without locking the connection" do
    @item.update!(access_token_expires_at: 1.hour.from_now)
    @item.expects(:with_lock).never

    assert_equal "old", @item.fresh_access_token
  end

  test "a token moomoo just refused is refreshed even before it expires" do
    @item.update!(access_token_expires_at: 1.hour.from_now)
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .returns(access_token: "new", refresh_token: nil, expires_in: 7200, scope: "")

    assert_equal "new", @item.with_access_token { |fresh| fresh.call(rejected: "old") }
  end

  test "a dead refresh token flags the connection for reconnecting" do
    Provider::Moomoo.any_instance.stubs(:refresh_access_token)
      .raises(Provider::Moomoo::MoomooError.new("expired", :invalid_grant, status: 400))

    assert_raises(Provider::Moomoo::MoomooError) { @item.with_access_token { |fresh| fresh.call } }

    @item.reload
    assert @item.requires_update?
    assert_equal "invalid_grant", @item.reauth_reason
    assert @item.needs_authorization?
  end

  test "a dead refresh token doesn't flag a connection reconnected after the refresh failed" do
    Provider::Moomoo.any_instance.stubs(:refresh_access_token)
      .raises(Provider::Moomoo::MoomooError.new("expired", :invalid_grant, status: 400))
    # The reconnect commits once the refresh has released the row lock.
    @item.define_singleton_method(:fresh_access_token) do |rejected: nil|
      super(rejected: rejected)
    rescue Provider::Moomoo::MoomooError
      MoomooItem.find(id).update!(refresh_token: "rt-reconnected", access_token: "at-reconnected")
      raise
    end

    assert_raises(Provider::Moomoo::MoomooError) { @item.with_access_token { |fresh| fresh.call } }

    @item.reload
    assert @item.good?
    assert_equal "rt-reconnected", @item.refresh_token
  end

  test "a transient token failure leaves the connection good" do
    @item.update!(access_token_expires_at: 1.minute.ago)
    Provider::Moomoo.any_instance.stubs(:refresh_access_token)
      .raises(Provider::Moomoo::MoomooError.new("unavailable", :token_failed, status: 503))

    assert_raises(Provider::Moomoo::MoomooError) { @item.with_access_token { |fresh| fresh.call } }

    assert @item.reload.good?
  end

  test "a transient failure of an early refresh keeps the stored token in use" do
    Provider::Moomoo.any_instance.expects(:refresh_access_token).once
      .raises(Provider::Moomoo::MoomooError.new("unavailable", :token_failed, status: 503))

    tokens = @item.with_access_token { |fresh| [ fresh.call, fresh.call ] }

    assert_equal %w[old old], tokens
    assert @item.reload.good?
  end

  test "a refused token is not used again when its refresh fails" do
    @item.update!(access_token_expires_at: 1.hour.from_now)
    Provider::Moomoo.any_instance.stubs(:refresh_access_token)
      .raises(Provider::Moomoo::MoomooError.new("unavailable", :token_failed, status: 503))

    error = assert_raises(Provider::Moomoo::MoomooError) { @item.with_access_token { |fresh| fresh.call(rejected: "old") } }
    assert_equal :token_failed, error.error_type
  end

  test "a connection without tokens is not authorized" do
    @item.update!(access_token: nil, refresh_token: nil)

    error = assert_raises(Provider::Moomoo::MoomooError) { @item.with_access_token { |fresh| fresh.call } }
    assert_equal :not_connected, error.error_type
  end

  test "an OAuth client is registered once per redirect URI" do
    item = @family.moomoo_items.create!(name: "moomoo")
    Provider::Moomoo.expects(:register_client).with(redirect_uri: CALLBACK_URL).once
      .returns(client_id: "cid-1", registration_access_token: "rat", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/cid-1", scope: "trade:read accid:*")

    item.ensure_oauth_client!(redirect_uri: CALLBACK_URL)
    item.ensure_oauth_client!(redirect_uri: CALLBACK_URL)

    assert_equal "cid-1", item.oauth_client_id
    assert_equal CALLBACK_URL, item.oauth_redirect_uri
    assert_equal "trade:read accid:*", item.oauth_registered_scope
    assert_equal "rat", item.oauth_registration_access_token
  end

  test "a moved host or a forgotten registration registers a new client" do
    item = @family.moomoo_items.create!(name: "moomoo", oauth_client_id: "client-1", oauth_redirect_uri: CALLBACK_URL)
    Provider::Moomoo.expects(:register_client).with(redirect_uri: "https://money.example.com/moomoo_items/callback")
      .returns(client_id: "cid-2", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    item.ensure_oauth_client!(redirect_uri: "https://money.example.com/moomoo_items/callback")
    assert_equal "cid-2", item.oauth_client_id

    item.update!(status: :requires_update, reauth_reason: "invalid_client")
    Provider::Moomoo.expects(:register_client).with(redirect_uri: "https://money.example.com/moomoo_items/callback")
      .returns(client_id: "cid-3", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    item.ensure_oauth_client!(redirect_uri: "https://money.example.com/moomoo_items/callback")
    assert_equal "cid-3", item.oauth_client_id
  end

  test "authorization stores the tokens and the granted scope" do
    @item.update!(access_token: nil, refresh_token: nil, status: :requires_update, reauth_reason: "invalid_grant")
    expect_exchange(scope: "trade:read accid:1")

    @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-1")

    @item.reload
    assert @item.good?
    assert_nil @item.reauth_reason
    assert_equal "at", @item.access_token
    assert_equal "rt", @item.refresh_token
    assert_equal "trade:read accid:1", @item.oauth_scope
  end

  test "a grant without trade:read or a trading account is refused and leaves the connection as it was" do
    [ "quote:read", "trade:read" ].each do |scope|
      expect_exchange(scope: scope)

      error = assert_raises(Provider::Moomoo::MoomooError) { @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-1") }

      assert_equal :scope_missing, error.error_type
      @item.reload
      assert @item.good?
      assert_nil @item.reauth_reason
      assert_equal [ "old", "r" ], [ @item.access_token, @item.refresh_token ]
    end
  end

  test "a grant that can place orders is refused and nothing is stored" do
    pending = @family.moomoo_items.create!(name: "moomoo", oauth_client_id: "client-1", oauth_redirect_uri: CALLBACK_URL)

    [ [ pending, "trade:read trade:write accid:1" ], [ @item, "trade:write accid:1" ] ].each do |item, scope|
      expect_exchange(scope: scope)

      error = assert_raises(Provider::Moomoo::MoomooError) { item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-1") }

      assert_equal :write_scope_granted, error.error_type
    end

    assert_not pending.reload.connected?
    assert_nil pending.oauth_scope
    assert_not_includes MoomooItem.syncable, pending
    @item.reload
    assert_equal [ "old", "r", nil ], [ @item.access_token, @item.refresh_token, @item.oauth_scope ]
  end

  test "a consent for another address registers a pending client and keeps the stored one" do
    moved = "https://money.example.com/moomoo_items/callback"
    Provider::Moomoo.expects(:register_client).with(redirect_uri: moved).twice
      .returns(client_id: "client-2", registration_access_token: "rat-2", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/client-2", scope: nil)
      .then.returns(client_id: "client-3", registration_access_token: "rat-3", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/client-3", scope: nil)

    assert_equal "client-1", @item.oauth_client_for_consent!(redirect_uri: CALLBACK_URL)
    2.times { assert_equal "client-2", @item.oauth_client_for_consent!(redirect_uri: moved) }

    @item.reload
    assert_equal [ "client-1", CALLBACK_URL ], [ @item.oauth_client_id, @item.oauth_redirect_uri ]
    assert_equal "client-1", @item.moomoo_provider.client_id
    assert_equal [ "client-2", moved, "rat-2", "https://webapi.moomoo.com/oauth2/register/client-2" ],
                 @item.pending_oauth_client.values_at("client_id", "redirect_uri", "registration_access_token", "registration_client_uri")

    # One never used since may be gone from moomoo by a later attempt.
    travel MoomooItem::PENDING_CLIENT_REUSE + 1.minute
    assert_equal "client-3", @item.oauth_client_for_consent!(redirect_uri: moved)
  end

  test "a consent run with a pending client moves the connection onto it only once it is granted" do
    moved = "https://money.example.com/moomoo_items/callback"
    @item.update!(pending_oauth_client: {
      "client_id" => "client-2", "redirect_uri" => moved, "scope" => nil,
      "registration_access_token" => "rat-2", "registration_client_uri" => "https://webapi.moomoo.com/oauth2/register/client-2"
    })
    Provider::Moomoo.any_instance.stubs(:exchange_code).with(code: "c1", redirect_uri: moved, code_verifier: "v1")
      .returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read trade:write accid:1")
      .then.returns(access_token: "at", refresh_token: nil, expires_in: 7200, scope: "trade:read accid:1")
      .then.returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read accid:1")

    # Refused, then without a refresh token of its own: the stored one belongs to the stored client.
    %i[write_scope_granted token_failed].each do |error_type|
      error = assert_raises(Provider::Moomoo::MoomooError) { @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-2") }
      assert_equal error_type, error.error_type
      @item.reload
      assert_equal [ "client-1", CALLBACK_URL, "old", "r" ], [ @item.oauth_client_id, @item.oauth_redirect_uri, @item.access_token, @item.refresh_token ]
      assert_equal "client-2", @item.pending_oauth_client["client_id"]
    end

    # A consent started with a client registered over since can't finish.
    error = assert_raises(Provider::Moomoo::MoomooError) { @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-0") }
    assert_equal :client_replaced, error.error_type

    @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-2")

    @item.reload
    assert_equal [ "client-2", moved, "rat-2", "https://webapi.moomoo.com/oauth2/register/client-2" ],
                 [ @item.oauth_client_id, @item.oauth_redirect_uri, @item.oauth_registration_access_token, @item.oauth_registration_client_uri ]
    assert_equal [ "at", "rt" ], [ @item.access_token, @item.refresh_token ]
    assert_nil @item.pending_oauth_client
  end

  test "a consent run with a registration a newer one replaced still finishes, and the newer one stays pending" do
    moved = "https://money.example.com/moomoo_items/callback"
    registration = ->(client_id) { { client_id: client_id, registration_access_token: "rat-#{client_id}", registration_client_uri: nil, scope: nil } }
    Provider::Moomoo.stubs(:register_client).returns(registration.("client-2")).then.returns(registration.("client-3"))
    assert_equal "client-2", @item.oauth_client_for_consent!(redirect_uri: moved)
    travel MoomooItem::PENDING_CLIENT_REUSE + 1.minute
    assert_equal "client-3", @item.oauth_client_for_consent!(redirect_uri: moved)
    Provider::Moomoo.any_instance.stubs(:exchange_code).returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read accid:1")

    @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-2")
    assert_equal [ "client-2", "rat-client-2" ], [ @item.reload.oauth_client_id, @item.oauth_registration_access_token ]
    assert_equal "client-3", @item.pending_oauth_client["client_id"]

    @item.complete_authorization!(code: "c2", code_verifier: "v2", client_id: "client-3")
    assert_equal [ "client-3", "rat-client-3" ], [ @item.reload.oauth_client_id, @item.oauth_registration_access_token ]
    assert_nil @item.pending_oauth_client
  end

  test "a new connection's consent doesn't replace one completed meanwhile" do
    expect_exchange(scope: "trade:read accid:2")

    error = assert_raises(Provider::Moomoo::MoomooError) { @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-1", new_connection: true) }

    assert_equal :already_connected, error.error_type
    @item.reload
    assert_equal [ "old", "r" ], [ @item.access_token, @item.refresh_token ]
    assert @item.good?
  end

  test "a token without any scope is accepted for the first sync to test" do
    expect_exchange(scope: "")

    @item.complete_authorization!(code: "c1", code_verifier: "v1", client_id: "client-1")

    assert @item.reload.good?
    assert_nil @item.oauth_scope
  end

  test "only connected, active connections sync" do
    deleting = @family.moomoo_items.create!(name: "moomoo", refresh_token: "r2", scheduled_for_deletion: true)
    pending = @family.moomoo_items.create!(name: "moomoo", oauth_client_id: "client-1")

    syncable = MoomooItem.syncable

    assert_includes syncable, @item
    assert_not_includes syncable, deleting
    assert_not_includes syncable, pending
    assert_not_includes syncable, moomoo_items(:pending_item)
  end

  test "a new connection reuses one that never finished authorizing" do
    family = families(:dylan_family)

    assert_no_difference -> { family.moomoo_items.count } do
      assert_equal moomoo_items(:pending_item), family.moomoo_item_for_new_connection(redirect_uri: CALLBACK_URL)
    end
  end

  test "Connect doesn't register again a connection that a consent completes meanwhile" do
    family = families(:dylan_family)
    pending = moomoo_items(:pending_item)
    stub_request(:post, "#{Provider::Moomoo::BASE_URL}#{Provider::Moomoo::REGISTER_PATH}").to_return do
      # Its own consent completes while this registration is made.
      MoomooItem.find(pending.id).update!(access_token: "at-1", refresh_token: "rt-1") unless MoomooItem.find(pending.id).connected?
      { status: 201, body: { client_id: "cid-#{SecureRandom.hex(4)}" }.to_json }
    end

    item = family.moomoo_item_for_new_connection(redirect_uri: "http://sure.lan/moomoo_items/callback")

    assert_not_equal pending, item
    assert_equal "http://sure.lan/moomoo_items/callback", item.oauth_redirect_uri
    assert_not item.connected?
    pending.reload
    assert_equal [ "test-client-id", "http://www.example.com/moomoo_items/callback", "rt-1" ], [ pending.oauth_client_id, pending.oauth_redirect_uri, pending.refresh_token ]
  end

  test "a failed registration keeps a new connection that a consent completed meanwhile" do
    family = families(:dylan_family)
    moomoo_items(:pending_item).destroy!
    stub_request(:post, "#{Provider::Moomoo::BASE_URL}#{Provider::Moomoo::REGISTER_PATH}").to_return do
      # Another tab's Connect reused the connection and its consent completed.
      # (Sure registers a second time without a scope after a refusal.)
      family.moomoo_items.where(refresh_token: nil).ordered.first&.update!(access_token: "at-1", refresh_token: "rt-1")
      { status: 400, body: { error: "invalid_redirect_uri" }.to_json }
    end

    assert_difference -> { family.moomoo_items.count }, 1 do
      assert_raises(Provider::Moomoo::MoomooError) do
        family.moomoo_item_for_new_connection(redirect_uri: "http://sure.lan/moomoo_items/callback")
      end
    end
    assert family.moomoo_items.ordered.first.connected?
  end

  test "a pending registration's token stays out of the SQL log and inspect" do
    Provider::Moomoo.stubs(:register_client)
      .returns(client_id: "client-2", registration_access_token: "rat-secret-2", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/client-2", scope: nil)
    log = StringIO.new
    logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(log, level: :debug)
    begin
      @item.oauth_client_for_consent!(redirect_uri: "https://money.example.com/moomoo_items/callback")
    ensure
      ActiveRecord::Base.logger = logger
    end

    assert_includes log.string, "pending_oauth_client"
    assert_not_includes log.string, "rat-secret-2"
    assert_not_includes @item.reload.inspect, "rat-secret-2"
  end

  test "a connection idle for over 10 days warns before moomoo ends it" do
    @item.update!(last_token_refresh_at: 11.days.ago)
    assert @item.token_inactive_soon?

    @item.update!(last_token_refresh_at: 2.days.ago)
    assert_not @item.token_inactive_soon?
  end

  private

    def expect_exchange(scope:)
      Provider::Moomoo.any_instance.expects(:exchange_code)
        .with(code: "c1", redirect_uri: CALLBACK_URL, code_verifier: "v1")
        .returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: scope)
    end
end
