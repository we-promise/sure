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
