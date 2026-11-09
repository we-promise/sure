# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class Provider::TricountTest < ActiveSupport::TestCase
  include TricountTestHelper

  BASE = "https://api.tricount.bunq.com"

  setup do
    @device = { app_installation_uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_public_key: "-----BEGIN RSA PUBLIC KEY-----\nKEY\n-----END RSA PUBLIC KEY-----\n" }
  end

  def stub_registration(token: "session-1", user_id: 42)
    stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .with(body: hash_including("app_installation_uuid" => @device[:app_installation_uuid], "client_public_key" => @device[:client_public_key]))
      .to_return(status: 200, body: { Response: [ { Token: { token: token } }, { UserPerson: { id: user_id } } ] }.to_json)
  end

  test "a new device is an installation UUID and a PKCS#1 RSA public key" do
    device = Provider::Tricount.generate_device

    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, device[:app_installation_uuid])
    assert device[:client_public_key].start_with?("-----BEGIN RSA PUBLIC KEY-----\n")
    key = OpenSSL::ASN1.decode(Base64.decode64(device[:client_public_key].lines[1..-2].join))
    assert_equal 2048, key.value.first.value.num_bits
  end

  test "the sharing token is read from a tricount link or taken as is" do
    assert_equal "tAbC123xyz", Provider::Tricount.sharing_token_from("https://tricount.com/tAbC123xyz")
    assert_equal "tAbC123xyz", Provider::Tricount.sharing_token_from(" https://www.tricount.com/en/tAbC123xyz/ ")
    assert_equal "tAbC123xyz", Provider::Tricount.sharing_token_from("tAbC123xyz")
    assert_nil Provider::Tricount.sharing_token_from("https://example.com/")
    assert_nil Provider::Tricount.sharing_token_from("not a link")
  end

  test "registering returns the session and hands it to the caller" do
    stub_registration
    sessions = []
    client = Provider::Tricount.new(**@device, on_session: ->(session) { sessions << session })

    session = client.register!

    assert_equal [ "session-1", "42" ], [ session.token, session.user_id ]
    assert_equal [ session ], sessions
  end

  test "requests present a current Tricount app version, or the configured override" do
    override = "com.bunq.tricount.android:RELEASE:99.0.0:1:ANDROID:15:C"
    session = { status: 200, body: { Response: [ { Token: { token: "s" } }, { UserPerson: { id: 1 } } ] }.to_json }
    default_request = stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .with(headers: { "User-Agent" => Provider::Tricount::DEFAULT_USER_AGENT }).to_return(session)
    override_request = stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .with(headers: { "User-Agent" => override }).to_return(session)

    with_env_overrides("TRICOUNT_APP_USER_AGENT" => nil) { Provider::Tricount.new(**@device).register! }
    with_env_overrides("TRICOUNT_APP_USER_AGENT" => override) { Provider::Tricount.new(**@device).register! }

    assert_requested default_request, times: 1
    assert_requested override_request, times: 1
    assert_no_match(/RELEASE:7\./, Provider::Tricount::DEFAULT_USER_AGENT)
  end

  # Tricount refuses app versions below its minimum with a 422 asking for an update.
  test "a refused app version is a clear client_outdated error" do
    stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .to_return(status: 422, body: { Error: [ { error_description: "Please update your app to unlock our newest features and enhancements." } ] }.to_json)

    error = assert_raises(Provider::Tricount::Error) { Provider::Tricount.new(**@device).register! }

    assert_equal :client_outdated, error.error_type
    assert_match(/TRICOUNT_APP_USER_AGENT/, error.message)
  end

  OUTDATED = { status: 422, body: { Error: [ { error_description: "Please update your app to unlock our newest features and enhancements." } ] }.to_json }.freeze
  SESSION = { status: 200, body: { Response: [ { Token: { token: "s" } }, { UserPerson: { id: 1 } } ] }.to_json }.freeze

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  test "a refused app version is retried once with the fallback version, which is then remembered" do
    with_memory_cache do
      refused = stub_request(:post, "#{BASE}/v1/session-registry-installation")
        .with(headers: { "User-Agent" => Provider::Tricount::DEFAULT_USER_AGENT }).to_return(OUTDATED)
      fallback = stub_request(:post, "#{BASE}/v1/session-registry-installation")
        .with(headers: { "User-Agent" => Provider::Tricount::FALLBACK_USER_AGENT }).to_return(SESSION)

      with_env_overrides("TRICOUNT_APP_USER_AGENT" => nil, "TRICOUNT_FALLBACK_APP_USER_AGENT" => nil) do
        assert_difference -> { DebugLogEntry.where(provider_key: "tricount", level: "warn").count }, 1 do
          assert_equal "s", Provider::Tricount.new(**@device).register!.token
        end
        # A later sync goes straight to the fallback instead of being refused again.
        Provider::Tricount.new(**@device).register!
      end

      assert_requested refused, times: 1
      assert_requested fallback, times: 2
    end
  end

  test "the fallback version can be overridden" do
    override = "com.bunq.tricount.android:RELEASE:50.0.0:1:ANDROID:15:C"
    stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .with(headers: { "User-Agent" => Provider::Tricount::DEFAULT_USER_AGENT }).to_return(OUTDATED)
    fallback = stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .with(headers: { "User-Agent" => override }).to_return(SESSION)

    with_env_overrides("TRICOUNT_APP_USER_AGENT" => nil, "TRICOUNT_FALLBACK_APP_USER_AGENT" => override) do
      Provider::Tricount.new(**@device).register!
    end

    assert_requested fallback, times: 1
  end

  test "when the fallback version is refused too, the error is still client_outdated" do
    requests = stub_request(:post, "#{BASE}/v1/session-registry-installation").to_return(OUTDATED)

    error = with_env_overrides("TRICOUNT_APP_USER_AGENT" => nil, "TRICOUNT_FALLBACK_APP_USER_AGENT" => nil) do
      assert_raises(Provider::Tricount::Error) { Provider::Tricount.new(**@device).register! }
    end

    assert_equal :client_outdated, error.error_type
    assert_requested requests, times: 2
  end

  test "any other 422 stays an unexpected response" do
    stub_request(:post, "#{BASE}/v1/session-registry-installation")
      .to_return(status: 422, body: { Error: [ { error_description: "Something else." } ] }.to_json)

    error = assert_raises(Provider::Tricount::Error) { Provider::Tricount.new(**@device).register! }

    assert_equal :unknown, error.error_type
    # Only a refused app version tries the fallback.
    assert_requested :post, "#{BASE}/v1/session-registry-installation", times: 1
  end

  test "every request carries its own request id" do
    ids = []
    capture = ->(request) { ids << request.headers["X-Bunq-Client-Request-Id"] }
    stub_request(:post, "#{BASE}/v1/session-registry-installation").with { |request| capture.call(request) }
      .to_return(status: 200, body: { Response: [ { Token: { token: "session-1" } }, { UserPerson: { id: 42 } } ] }.to_json)
    stub_request(:post, "#{BASE}/v1/user/42/registry-synchronization").with { |request| capture.call(request) }
      .to_return(status: 200, body: { Response: [] }.to_json)
    stub_request(:get, "#{BASE}/v1/user/42/registry").with(query: { public_identifier_token: SHARING_TOKEN }) { |request| capture.call(request) }
      .to_return(status: 200, body: { Response: [ { Registry: tricount_registry } ] }.to_json)
    client = Provider::Tricount.new(**@device)

    client.synchronize!([ SHARING_TOKEN ])
    2.times { client.registry(SHARING_TOKEN) }

    # Four requests (WebMock may evaluate a matcher more than once per request).
    assert_equal 4, ids.uniq.size, "requests shared a request id: #{ids.tally.values.inspect}"
  end

  test "reading a tricount registers first, synchronises its token and sends the session" do
    stub_registration
    sync = stub_request(:post, "#{BASE}/v1/user/42/registry-synchronization")
      .with(headers: { "X-Bunq-Client-Authentication" => "session-1" }, body: hash_including("all_registry_active" => [ { "public_identifier_token" => SHARING_TOKEN } ]))
      .to_return(status: 200, body: { Response: [] }.to_json)
    stub_request(:get, "#{BASE}/v1/user/42/registry").with(query: { public_identifier_token: SHARING_TOKEN })
      .to_return(status: 200, body: { Response: [ { Registry: tricount_registry } ] }.to_json)
    client = Provider::Tricount.new(**@device)

    client.synchronize!([ SHARING_TOKEN ])
    registry = client.registry(SHARING_TOKEN)

    assert_requested sync
    assert_equal REGISTRY_UUID, registry["uuid"]
    assert_equal 5, registry["all_registry_entry"].size
  end

  test "an expired session is registered again once" do
    stub_registration(token: "session-2")
    stub_request(:get, "#{BASE}/v1/user/42/registry").with(query: { public_identifier_token: SHARING_TOKEN })
      .with(headers: { "X-Bunq-Client-Authentication" => "stale" }).to_return(status: 401, body: "{}")
    stub_request(:get, "#{BASE}/v1/user/42/registry").with(query: { public_identifier_token: SHARING_TOKEN })
      .with(headers: { "X-Bunq-Client-Authentication" => "session-2" })
      .to_return(status: 200, body: { Response: [ { Registry: tricount_registry } ] }.to_json)
    client = Provider::Tricount.new(**@device, session_token: "stale", user_id: "42")

    assert_equal REGISTRY_UUID, client.registry(SHARING_TOKEN)["uuid"]
    assert_equal "session-2", client.session_token
  end

  test "a session refused right after registering is an authentication error" do
    stub_registration
    stub_request(:get, "#{BASE}/v1/user/42/registry").with(query: { public_identifier_token: SHARING_TOKEN }).to_return(status: 401, body: "{}")

    assert_raises(Provider::Tricount::AuthenticationError) do
      Provider::Tricount.new(**@device).registry(SHARING_TOKEN)
    end
  end
end
