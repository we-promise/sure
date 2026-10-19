require "test_helper"

class Provider::ScalableTest < ActiveSupport::TestCase
  class FakeHttpResponse
    attr_reader :code

    def initialize(status:, headers: {}, chunks: [])
      @code = status.to_s
      @headers = headers
      @chunks = chunks
    end

    def each_header
      return enum_for(:each_header) unless block_given?

      @headers.each { |name, value| yield name.downcase, value }
    end

    def read_body
      return enum_for(:read_body) unless block_given?

      @chunks.each { |chunk| yield chunk }
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :last_request

    def initialize(response)
      @response = response
    end

    def request(request)
      @last_request = request
      yield @response
      @response
    end
  end

  setup do
    @rsa = OpenSSL::PKey::RSA.generate(2_048)
  end

  test "error codes are fixed and messages do not expose upstream detail" do
    ScalableItem::ERROR_CODES.each do |code|
      error = Provider::Scalable::Error.new(code)
      assert_equal code, error.code
      assert_nil error.details
      assert_equal code, error.as_json[:code]
    end

    assert_equal "sync_failed", Provider::Scalable::Error.new("refresh-token-secret").code
    assert_equal "authentication_failed", Provider::Scalable::Error.new(:access_denied).code
    assert_equal "challenge_expired", Provider::Scalable::Error.new(:device_login_expired).code
    assert_equal "provider_unavailable", Provider::Scalable::Error.new(:request_timeout).code
    refute_includes Provider::Scalable::Error.new(:provider_unavailable).message, "refresh-token-secret"
  end

  test "DPoP proof signs the canonical target and access token hash" do
    provider = Provider::Scalable.new
    private_key_pem = provider.send(:generate_dpop_key_pem)
    token = "opaque-access-token"
    proof = provider.send(
      :dpop_proof,
      private_key_pem,
      "https://de.scalable.capital/api/cli/graphql?x=1#fragment",
      method: "post",
      nonce: "nonce-1",
      access_token: token
    )
    key = OpenSSL::PKey.read(private_key_pem)
    claims, header = JWT.decode(proof, key, true, algorithms: [ "ES256" ])

    assert_equal "dpop+jwt", header["typ"]
    assert_equal "EC", header.dig("jwk", "kty")
    assert_equal "P-256", header.dig("jwk", "crv")
    assert_equal "POST", claims["htm"]
    assert_equal "https://de.scalable.capital/api/cli/graphql", claims["htu"]
    assert_equal "nonce-1", claims["nonce"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(token), padding: false), claims["ath"]
    jwk = header.fetch("jwk")
    canonical_jwk = JSON.generate("crv" => jwk.fetch("crv"), "kty" => jwk.fetch("kty"), "x" => jwk.fetch("x"), "y" => jwk.fetch("y"))
    expected_thumbprint = Base64.urlsafe_encode64(Digest::SHA256.digest(canonical_jwk), padding: false)
    assert_equal expected_thumbprint, provider.send(:dpop_thumbprint, private_key_pem)
    refute_includes proof, token
  end

  test "OAuth requests retry once with a DPoP nonce and stop after the retry" do
    provider = Provider::Scalable.new
    private_key_pem = provider.send(:generate_dpop_key_pem)
    calls = queue_http(
      provider,
      response(401, { "error" => "use_dpop_nonce" }, headers: { "DPoP-Nonce" => "nonce-1" }),
      response(401, { "error" => "use_dpop_nonce" }, headers: { "DPoP-Nonce" => "nonce-2" }),
      response(200, { "access_token" => "must-not-be-requested" })
    )

    result = provider.send(
      :post_form,
      Provider::Scalable::TOKEN_URL,
      { "grant_type" => "refresh_token" },
      key_pem: private_key_pem,
      allowed_hosts: [ Provider::Scalable::AUTH_HOST ]
    )

    assert_equal 401, result.status
    assert_equal 2, calls.length
    first_claims, = JWT.decode(calls.fetch(0).fetch(:headers).fetch("DPoP"), OpenSSL::PKey.read(private_key_pem), false)
    retry_claims, = JWT.decode(calls.fetch(1).fetch(:headers).fetch("DPoP"), OpenSSL::PKey.read(private_key_pem), false)
    assert_nil first_claims["nonce"]
    assert_equal "nonce-1", retry_claims.fetch("nonce")
  end

  test "transport returns streamed status and rejects redirects and oversized bodies" do
    provider = Provider::Scalable.new
    raw_response = FakeHttpResponse.new(status: 200, headers: { "content-type" => "application/json" }, chunks: [ "{}" ])
    fake_http = FakeHttp.new(raw_response)
    constructor_args = nil
    response = Net::HTTP.stub(:new, ->(*args) { constructor_args = args; fake_http }) do
      provider.send(
        :http_request,
        Provider::Scalable::TOKEN_URL,
        method: :post,
        body: "grant_type=device_code",
        headers: { "Content-Type" => "application/x-www-form-urlencoded" },
        allowed_hosts: [ Provider::Scalable::AUTH_HOST ]
      )
    end

    assert_equal [ Provider::Scalable::AUTH_HOST, 443, nil ], constructor_args
    assert_equal 200, response.status
    assert_equal "{}", response.body
    assert_equal "/oauth/token", fake_http.last_request.path
    assert_equal "grant_type=device_code", fake_http.last_request.body
    assert_equal "application/x-www-form-urlencoded", fake_http.last_request["Content-Type"]

    redirect = Provider::Scalable::Transport::Response.new(status: 302, headers: {}, body: "")
    error = assert_raises(Provider::Scalable::Error) { provider.send(:reject_redirect!, redirect) }
    assert_equal "invalid_response", error.code

    too_large_http = FakeHttp.new(
      FakeHttpResponse.new(
        status: 200,
        chunks: [ "x" * (Provider::Scalable::Transport::MAX_RESPONSE_BYTES + 1) ]
      )
    )
    error = Net::HTTP.stub(:new, too_large_http) do
      assert_raises(Provider::Scalable::Error) do
        provider.send(
          :http_request,
          Provider::Scalable::TOKEN_URL,
          method: :get,
          allowed_hosts: [ Provider::Scalable::AUTH_HOST ]
        )
      end
    end
    assert_equal "invalid_response", error.code

    error = assert_raises(Provider::Scalable::Error) do
      provider.send(:validate_https_uri!, "https://attacker.example/jwks", allowed_hosts: [ Provider::Scalable::AUTH_HOST ])
    end
    assert_equal "invalid_response", error.code
  end

  test "token verification checks signature, issuer, audience, person identity, and DPoP binding" do
    private_key_pem = Provider::Scalable.new.send(:generate_dpop_key_pem)
    provider = Provider::Scalable.new
    claims = verified_claims(person_id: "person-1", session_id: "session-1")
    queue_http(provider, discovery_response, jwks_response)

    verified = provider.send(:verify_access_token!, signed_token(claims), private_key_pem: private_key_pem)

    assert_equal "person-1", verified["person_id"]
    assert_equal "session-1", verified["session_id"]
    assert_equal claims.fetch("exp"), verified["exp"]

    invalid_tokens = [
      signed_token(claims.merge("iss" => "https://attacker.example/")),
      signed_token(claims.merge("aud" => "wrong-audience")),
      signed_token(claims.merge("cnf" => { "jkt" => "another-key" }))
    ]
    invalid_tokens.each do |token|
      verifier = Provider::Scalable.new
      queue_http(verifier, discovery_response, jwks_response)
      error = assert_raises(Provider::Scalable::Error) do
        verifier.send(:verify_access_token!, token, private_key_pem: private_key_pem)
      end
      assert_equal "authentication_failed", error.code
    end

    header, payload, signature = signed_token(claims).split(".")
    signature_bytes = Base64.urlsafe_decode64(signature)
    signature_bytes.setbyte(0, signature_bytes.getbyte(0) ^ 1)
    tampered = [ header, payload, Base64.urlsafe_encode64(signature_bytes, padding: false) ].join(".")
    verifier = Provider::Scalable.new
    queue_http(verifier, discovery_response, jwks_response)
    error = assert_raises(Provider::Scalable::Error) do
      verifier.send(:verify_access_token!, tampered, private_key_pem: private_key_pem)
    end
    assert_equal "authentication_failed", error.code
  end

  test "device login is resumable, bounded, and authenticates only after strict verification" do
    provider = Provider::Scalable.new
    key_for_token = nil
    token = signed_token(verified_claims(person_id: "person-1", session_id: "session-1"))
    calls = queue_http(
      provider,
      response(200, {
        "device_code" => "device-1",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://secure.scalable.capital/device",
        "verification_uri_complete" => "https://secure.scalable.capital/device?user_code=ABCD-EFGH",
        "expires_in" => 7_200,
        "interval" => 1
      }),
      response(200, {
        "access_token" => token,
        "refresh_token" => "refresh-1",
        "id_token" => "id-1",
        "expires_in" => 3_600
      }),
      discovery_response,
      jwks_response,
      response(200, { "data" => { "is2faOnLoginEnabled" => { "enabled" => false } } })
    )

    pending = provider.start_login
    key_for_token = OpenSSL::PKey.read(pending.fetch("private_key_pem"))
    assert_equal "device", pending.fetch("phase")
    assert_equal "https://secure.scalable.capital/device?user_code=ABCD-EFGH", pending.fetch("verification_url")
    assert_equal 5, pending.fetch("poll_interval")
    assert_operator Time.iso8601(pending.fetch("expires_at")), :<=, Time.now.utc + Provider::Scalable::MAX_DEVICE_TTL_SECONDS
    pending["next_poll_at"] = Time.now.utc.iso8601

    result = provider.poll_login(pending)

    assert_equal :authenticated, result.state
    assert_nil result.pending_state
    assert_equal "person-1", result.credentials.fetch("person_id")
    assert_equal "refresh-1", result.credentials.fetch("refresh_token")
    assert_equal pending.fetch("private_key_pem"), result.credentials.fetch("private_key_pem")
    assert_equal 5, calls.length

    start_form = URI.decode_www_form(calls[0].fetch(:body)).to_h
    assert_equal Provider::Scalable::CLIENT_ID, start_form.fetch("client_id")
    assert_equal Provider::Scalable::AUDIENCE, start_form.fetch("audience")
    assert_equal "offline_access openid email", start_form.fetch("scope")
    assert_equal Provider::Scalable::DEVICE_CODE_URL, calls[0].fetch(:url)
    proof_claims, = JWT.decode(calls[0].fetch(:headers).fetch("DPoP"), key_for_token, true, algorithms: [ "ES256" ])
    assert_equal Provider::Scalable::DEVICE_CODE_URL, proof_claims.fetch("htu")
    assert_equal "DPoP #{token}", calls[4].fetch(:headers).fetch("Authorization")
  end

  test "phone approval advances one poll per call and withholds credentials while pending" do
    provider = Provider::Scalable.new
    token = signed_token(verified_claims(person_id: "person-1", session_id: "session-1"))
    calls = queue_http(
      provider,
      response(200, {
        "device_code" => "device-1",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://secure.scalable.capital/device",
        "expires_in" => 600,
        "interval" => 5
      }),
      response(200, { "access_token" => token, "refresh_token" => "refresh-1", "expires_in" => 3_600 }),
      discovery_response,
      jwks_response,
      response(200, { "data" => { "is2faOnLoginEnabled" => { "enabled" => true, "hasApprovedSession" => false } } }),
      response(200, { "data" => { "start2faOnLogin" => { "mfaSessionId" => "mfa-1" } } }),
      response(200, { "data" => { "validate2faOnLogin" => { "status" => "PENDING" } } }),
      response(200, { "data" => { "validate2faOnLogin" => { "status" => "SUCCESS" } } })
    )

    pending = provider.start_login
    pending["next_poll_at"] = Time.now.utc.iso8601
    first = provider.poll_login(pending)
    assert_equal :pending, first.state
    assert_equal "phone_approval", first.pending_state.fetch("phase")
    assert_equal 2, first.pending_state.fetch("poll_interval")
    assert_nil first.credentials
    assert first.pending_state.fetch("pending_credentials").fetch("access_token").present?
    assert_equal 7, calls.length

    early = provider.poll_login(first.pending_state)
    assert_equal :pending, early.state
    assert_equal 7, calls.length

    due_state = early.pending_state.merge("next_poll_at" => Time.now.utc.iso8601)
    complete = provider.poll_login(due_state)
    assert_equal :authenticated, complete.state
    assert_equal "person-1", complete.credentials.fetch("person_id")
    assert_equal 8, calls.length
  end

  test "refresh requires a rotated token and persists only a same-person replacement" do
    private_key_pem = Provider::Scalable.new.send(:generate_dpop_key_pem)
    old_token = signed_token(verified_claims(person_id: "person-1", session_id: "old-session", exp: 1))
    verifier = Provider::Scalable.new
    queue_http(verifier, discovery_response, jwks_response)
    assert_equal "old-session", verifier.send(:verify_access_token!, old_token, private_key_pem: private_key_pem, allow_expired: true).fetch("session_id")

    new_token = signed_token(verified_claims(person_id: "person-1", session_id: "new-session", exp: Time.now.to_i + 3_600))
    persisted = []
    provider = Provider::Scalable.new(
      credentials: credentials_hash(old_token, private_key_pem, expires_at: Time.now.utc.iso8601),
      on_credentials_update: ->(credentials) { persisted << credentials }
    )
    calls = queue_http(
      provider,
      discovery_response,
      jwks_response,
      response(200, { "access_token" => new_token, "refresh_token" => "refresh-2", "expires_in" => 3_600 })
    )

    rotated = provider.refresh_if_needed!

    assert_equal "refresh-2", rotated.fetch("refresh_token")
    assert_equal "person-1", provider.person_identity
    assert_equal [ rotated ], persisted
    refresh_form = URI.decode_www_form(calls.fetch(2).fetch(:body)).to_h
    assert_equal "refresh_token", refresh_form.fetch("grant_type")
    assert_equal "refresh-1", refresh_form.fetch("refresh_token")
    assert_equal "old-session", refresh_form.fetch("session_id")

    changed_token = signed_token(verified_claims(person_id: "person-2", exp: Time.now.to_i + 3_600))
    changed_provider = Provider::Scalable.new(
      credentials: credentials_hash(old_token, private_key_pem, expires_at: Time.now.utc.iso8601),
      on_credentials_update: ->(_credentials) { flunk "identity-changing credentials must not be persisted" }
    )
    queue_http(
      changed_provider,
      discovery_response,
      jwks_response,
      response(200, { "access_token" => changed_token, "refresh_token" => "refresh-2", "expires_in" => 3_600 })
    )
    error = assert_raises(Provider::Scalable::Error) { changed_provider.refresh_if_needed! }
    assert_equal "account_identity_changed", error.code
  end

  test "invalid_grant and missing replacement refresh token require a new login" do
    private_key_pem = Provider::Scalable.new.send(:generate_dpop_key_pem)
    old_token = signed_token(verified_claims(person_id: "person-1", exp: 1))
    provider = Provider::Scalable.new(credentials: credentials_hash(old_token, private_key_pem, expires_at: Time.now.utc.iso8601))
    queue_http(
      provider,
      discovery_response,
      jwks_response,
      response(400, { "error" => "invalid_grant", "error_description" => "private token detail" })
    )

    error = assert_raises(Provider::Scalable::Error) { provider.refresh_if_needed! }
    assert_equal "session_expired", error.code
    refute_includes error.message, "private token detail"

    replacement_token = signed_token(verified_claims(person_id: "person-1", exp: Time.now.to_i + 3_600))
    provider = Provider::Scalable.new(credentials: credentials_hash(old_token, private_key_pem, expires_at: Time.now.utc.iso8601))
    queue_http(
      provider,
      discovery_response,
      jwks_response,
      response(200, { "access_token" => replacement_token, "refresh_token" => " ", "expires_in" => 3_600 })
    )
    error = assert_raises(Provider::Scalable::Error) { provider.refresh_if_needed! }
    assert_equal "session_expired", error.code
  end

  test "read allows only a fixed query and persists refresh before retrying the read" do
    private_key_pem = Provider::Scalable.new.send(:generate_dpop_key_pem)
    old_token = signed_token(verified_claims(person_id: "person-1", session_id: "old-session", exp: Time.now.to_i + 3_600))
    new_token = signed_token(verified_claims(person_id: "person-1", session_id: "new-session", exp: Time.now.to_i + 7_200))
    events = []
    provider = Provider::Scalable.new(
      credentials: credentials_hash(old_token, private_key_pem, expires_at: (Time.now.utc + 3_600).iso8601),
      on_credentials_update: ->(_credentials) { events << :persisted }
    )
    calls = queue_http(
      provider,
      response(401, { "error" => "unauthorized" }),
      discovery_response,
      jwks_response,
      response(200, { "access_token" => new_token, "refresh_token" => "refresh-2", "expires_in" => 7_200 }),
      response(200, { "data" => { "account" => { "id" => "account-1", "brokerPortfolios" => [] } } })
    )
    original_http = provider.method(:http_request)
    provider.define_singleton_method(:http_request) do |url, **options|
      response = original_http.call(url, **options)
      if url == Provider::Scalable::GRAPHQL_URL && options[:headers]["Authorization"] == "DPoP #{new_token}"
        raise "rotated credentials must persist before the retried read" unless events == [ :persisted ]
      end
      response
    end

    error = assert_raises(Provider::Scalable::Error) { provider.read(:missing_operation) }
    assert_equal "invalid_response", error.code
    result = provider.read(:broker_portfolios, variables: { "id" => "account-1" })

    assert_equal "account-1", result.dig("account", "id")
    assert_equal [ :persisted ], events
    assert_equal "DPoP #{old_token}", calls.fetch(0).fetch(:headers).fetch("Authorization")
    assert_equal "DPoP #{new_token}", calls.fetch(4).fetch(:headers).fetch("Authorization")
    request = JSON.parse(calls.fetch(4).fetch(:body))
    assert_equal "ResolveBrokerIds", request.fetch("operation_name")
    assert_match(/\A\s*query\b/, request.fetch("query"))
  end

  private

    def response(status, payload, headers: {})
      Provider::Scalable::Transport::Response.new(
        status: status,
        headers: headers.transform_keys(&:downcase),
        body: payload.is_a?(String) ? payload : JSON.generate(payload)
      )
    end

    def queue_http(provider, *responses)
      calls = []
      queue = responses.dup
      provider.define_singleton_method(:http_request) do |url, method:, body: nil, headers: {}, allowed_hosts:|
        calls << {
          url: url,
          method: method,
          body: body,
          headers: headers,
          allowed_hosts: allowed_hosts
        }
        queue.shift || raise("unexpected HTTP request")
      end
      calls
    end

    def discovery_response
      response(200, {
        "issuer" => "https://secure.scalable.capital/",
        "jwks_uri" => "https://secure.scalable.capital/.well-known/jwks.json"
      })
    end

    def jwks_response
      response(200, {
        "keys" => [ {
          "kid" => "test-key",
          "kty" => "RSA",
          "use" => "sig",
          "alg" => "RS256",
          "n" => base64url_bn(@rsa.n),
          "e" => base64url_bn(@rsa.e)
        } ]
      })
    end

    def base64url_bn(number)
      hex = number.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      Base64.urlsafe_encode64([ hex ].pack("H*"), padding: false)
    end

    def verified_claims(person_id:, session_id: nil, exp: Time.now.to_i + 3_600, aud: Provider::Scalable::AUDIENCE, extra: {})
      claims = {
        "iss" => "https://secure.scalable.capital/",
        "aud" => aud,
        "exp" => exp,
        "iat" => Time.now.to_i - 1,
        "https://de.scalable.capital/person_id" => person_id
      }.merge(extra)
      claims["https://de.scalable.capital/session_id"] = session_id if session_id
      claims
    end

    def signed_token(claims)
      JWT.encode(claims, @rsa, "RS256", { "kid" => "test-key" })
    end

    def credentials_hash(access_token, private_key_pem, expires_at:)
      provider = Provider::Scalable.new
      {
        "access_token" => access_token,
        "refresh_token" => "refresh-1",
        "id_token" => nil,
        "expires_at" => expires_at,
        "person_id" => "person-1",
        "session_id" => nil,
        "private_key_pem" => private_key_pem,
        "dpop_jkt" => provider.send(:dpop_thumbprint, private_key_pem)
      }
    end
end
