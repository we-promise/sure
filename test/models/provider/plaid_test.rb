require "test_helper"

class Provider::PlaidTest < ActiveSupport::TestCase
  setup do
    # Do not change, this is whitelisted in the Plaid Dashboard for local dev
    @redirect_url = "http://localhost:3000/accounts"

    with_env_overrides(
      "PLAID_CLIENT_ID" => "foo",
      "PLAID_SECRET" => "bar"
    ) do
      Provider::PlaidAdapter.reload_configuration
    end

    # A specialization of Plaid client with sandbox-only extensions
    @plaid = Provider::PlaidSandbox.new
  end

  teardown do
    Provider::PlaidAdapter.reload_configuration
  end

  test "gets link token" do
    VCR.use_cassette("plaid/link_token") do
      link_token = @plaid.get_link_token(
        user_id: "test-user-id",
        webhooks_url: "https://example.com/webhooks",
        redirect_url: @redirect_url
      )

      assert_match /link-sandbox-.*/, link_token.link_token
    end
  end

  test "requests liability products only for liability account types" do
    request = mock
    Plaid::LinkTokenCreateRequest.expects(:new).with do |params|
      params[:products] == [ "investments" ] &&
        params[:additional_consented_products] == [ "transactions" ]
    end.returns(request)
    @plaid.client.expects(:link_token_create).with(request).returns("response")

    @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url,
      accountable_type: "Investment"
    )
  end

  test "does not request liabilities for a depository link" do
    request = mock
    Plaid::LinkTokenCreateRequest.expects(:new).with do |params|
      params[:products] == [ "transactions" ] &&
        params[:optional_products].nil? &&
        params[:additional_consented_products] == [ "investments" ]
    end.returns(request)
    @plaid.client.expects(:link_token_create).with(request).returns("response")

    @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url,
      accountable_type: "Depository"
    )
  end

  test "requests liabilities as an optional product for a credit card link" do
    request = mock
    Plaid::LinkTokenCreateRequest.expects(:new).with do |params|
      params[:products] == [ "transactions" ] &&
        params[:optional_products] == [ "liabilities" ] &&
        params[:required_if_supported_products].nil? &&
        params[:additional_consented_products] == [ "investments" ]
    end.returns(request)
    @plaid.client.expects(:link_token_create).with(request).returns("response")

    @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url,
      accountable_type: "CreditCard"
    )
  end

  test "requests liabilities as primary for a loan link" do
    request = mock
    Plaid::LinkTokenCreateRequest.expects(:new).with do |params|
      params[:products] == [ "liabilities" ] &&
        params[:optional_products].nil? &&
        params[:additional_consented_products] == [ "transactions", "investments" ]
    end.returns(request)
    @plaid.client.expects(:link_token_create).with(request).returns("response")

    @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url,
      accountable_type: "Loan"
    )
  end

  test "enables account selection for an update link token" do
    request = mock
    Plaid::LinkTokenCreateRequest.expects(:new).with do |params|
      params[:access_token] == "access-token" &&
        params[:update] == { account_selection_enabled: true } &&
        params[:products].nil? &&
        params[:transactions].nil?
    end.returns(request)
    @plaid.client.expects(:link_token_create).with(request).returns("response")

    result = @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url,
      access_token: "access-token",
      account_selection_enabled: true
    )

    assert_equal "response", result
  end

  test "exchanges public token" do
    VCR.use_cassette("plaid/exchange_public_token") do
      public_token = @plaid.create_public_token
      exchange_response = @plaid.exchange_public_token(public_token)

      assert_match /access-sandbox-.*/, exchange_response.access_token
    end
  end

  test "gets item" do
    VCR.use_cassette("plaid/get_item") do
      access_token = get_access_token
      item = @plaid.get_item(access_token).item

      assert_equal "ins_109508", item.institution_id
      assert_equal "First Platypus Bank", item.institution_name
    end
  end

  test "gets item accounts" do
    VCR.use_cassette("plaid/get_item_accounts") do
      access_token = get_access_token
      accounts_response = @plaid.get_item_accounts(access_token)

      assert_equal 4, accounts_response.accounts.size
    end
  end

  test "collects all transaction pages with the maximum page size" do
    pages = sequence("transaction pages")
    expect_transaction_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true, prefix: "first"))
    expect_transaction_page("page-2", pages).returns(transaction_page("complete", prefix: "second"))
    DebugLogEntry.expects(:capture).never

    result = @plaid.get_transactions("access-token", next_cursor: "saved-cursor")

    assert_equal [ "first-added", "second-added" ], result.added
    assert_equal [ "first-modified", "second-modified" ], result.modified
    assert_equal [ "first-removed", "second-removed" ], result.removed
    assert_equal "complete", result.cursor
  end

  test "restarts the entire transaction update and discards partial results" do
    pages = sequence("transaction pages")
    expect_transaction_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true, prefix: "discarded"))
    expect_transaction_page("page-2", pages).raises(transaction_mutation_error)
    expect_transaction_page("saved-cursor", pages).returns(transaction_page("retry-page-2", has_more: true, prefix: "retry-first"))
    expect_transaction_page("retry-page-2", pages).returns(transaction_page("complete", prefix: "retry-second"))
    expect_transaction_restart(1)

    result = @plaid.get_transactions("access-token", next_cursor: "saved-cursor")

    assert_equal [ "retry-first-added", "retry-second-added" ], result.added
    assert_equal [ "retry-first-modified", "retry-second-modified" ], result.modified
    assert_equal [ "retry-first-removed", "retry-second-removed" ], result.removed
    assert_equal "complete", result.cursor
  end

  test "restarts an initial transaction sync without a cursor" do
    pages = sequence("transaction pages")
    expect_transaction_page(nil, pages).returns(transaction_page("page-2", has_more: true, prefix: "discarded"))
    expect_transaction_page("page-2", pages).raises(transaction_mutation_error)
    expect_transaction_page(nil, pages).returns(transaction_page("complete"))
    expect_transaction_restart(1)

    result = @plaid.get_transactions("access-token")

    assert_equal [ "kept-added" ], result.added
    assert_equal [ "kept-modified" ], result.modified
    assert_equal [ "kept-removed" ], result.removed
    assert_equal "complete", result.cursor
  end

  test "allows three transaction pagination restarts" do
    pages = sequence("transaction pages")
    3.times do |index|
      expect_transaction_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true, prefix: "discarded"))
      expect_transaction_page("page-2", pages).raises(transaction_mutation_error)
      expect_transaction_restart(index + 1)
    end
    expect_transaction_page("saved-cursor", pages).returns(transaction_page("complete"))

    result = @plaid.get_transactions("access-token", next_cursor: "saved-cursor")

    assert_equal [ "kept-added" ], result.added
    assert_equal [ "kept-modified" ], result.modified
    assert_equal [ "kept-removed" ], result.removed
    assert_equal "complete", result.cursor
  end

  test "raises the Plaid error after exhausting transaction pagination restarts" do
    pages = sequence("transaction pages")
    error = transaction_mutation_error
    4.times do |index|
      expect_transaction_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true))
      expect_transaction_page("page-2", pages).raises(error)
      expect_transaction_restart(index + 1) if index < 3
    end

    raised = assert_raises(Plaid::ApiError) do
      @plaid.get_transactions("access-token", next_cursor: "saved-cursor")
    end

    assert_same error, raised
  end

  {
    "unrelated Plaid error" => '{"error_code":"ITEM_LOGIN_REQUIRED"}',
    "item limit error" => '{"error_code":"TRANSACTIONS_SYNC_ITEM_LIMIT_EXCEEDED"}',
    "malformed error body" => "not json",
    "missing error body" => nil,
    "missing error code" => "{}",
    "array error body" => "[]",
    "null error body" => "null",
    "string error body" => '"unexpected"'
  }.each do |description, body|
    test "does not restart transaction pagination for #{description}" do
      pages = sequence("transaction pages")
      error = Plaid::ApiError.new(code: 400, response_body: body)
      expect_transaction_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true))
      expect_transaction_page("page-2", pages).raises(error)
      DebugLogEntry.expects(:capture).never

      raised = assert_raises(Plaid::ApiError) do
        @plaid.get_transactions("access-token", next_cursor: "saved-cursor")
      end

      assert_same error, raised
    end
  end

  test "requests a transaction refresh" do
    @plaid.client.expects(:transactions_refresh).with do |request|
      request.access_token == "access-token"
    end

    @plaid.refresh_transactions("access-token")
  end

  test "gets item investments" do
    VCR.use_cassette("plaid/get_item_investments") do
      access_token = get_access_token
      investments_response = @plaid.get_item_investments(access_token)

      assert_equal 3, investments_response.holdings.size
      assert_equal 4, investments_response.transactions.size
    end
  end

  test "gets item liabilities" do
    VCR.use_cassette("plaid/get_item_liabilities") do
      access_token = get_access_token
      liabilities_response = @plaid.get_item_liabilities(access_token)

      assert liabilities_response.credit.count > 0
      assert liabilities_response.student.count > 0
    end
  end

  test "requests the full history window when syncing transactions" do
    response = stub(added: [], modified: [], removed: [], has_more: false, next_cursor: "cursor")

    @plaid.client.expects(:transactions_sync).with { |request|
      request.options[:days_requested] == Provider::Plaid::MAX_HISTORY_DAYS &&
        request.options[:include_original_description] == true
    }.returns(response)

    @plaid.get_transactions("access-token")
  end

  test "verifies a webhook token against the JWK published for its kid" do
    provider, jwk, key, body = verified_webhook_setup

    token = JWT.encode(
      { iat: Time.current.to_i, request_body_sha256: Digest::SHA256.hexdigest(body) },
      key, "ES256", { "kid" => jwk.kid }
    )

    assert_nothing_raised { provider.validate_webhook!(token, body) }
  end

  test "rejects webhook tokens signed by a key with a matching kid but different bytes" do
    provider, jwk, = verified_webhook_setup
    impostor = OpenSSL::PKey::EC.generate("prime256v1")

    token = JWT.encode(
      { iat: Time.current.to_i, request_body_sha256: Digest::SHA256.hexdigest("{}") },
      impostor, "ES256", { "kid" => jwk.kid }
    )

    assert_raises JWT::VerificationError do
      provider.validate_webhook!(token, "{}")
    end
  end

  test "rejects webhook tokens whose body hash does not match the raw body" do
    provider, jwk, key, body = verified_webhook_setup
    token = JWT.encode(
      { iat: Time.current.to_i, request_body_sha256: Digest::SHA256.hexdigest(body) },
      key, "ES256", { "kid" => jwk.kid }
    )

    assert_raises JWT::VerificationError do
      provider.validate_webhook!(token, body + " ")
    end
  end

  test "rejects webhook tokens issued more than five minutes ago" do
    provider, jwk, key, body = verified_webhook_setup
    token = JWT.encode(
      { iat: 6.minutes.ago.to_i, request_body_sha256: Digest::SHA256.hexdigest(body) },
      key, "ES256", { "kid" => jwk.kid }
    )

    assert_raises JWT::VerificationError do
      provider.validate_webhook!(token, body)
    end
  end

  test "rejects webhook tokens signed with an unsupported algorithm" do
    provider, jwk, _key, body = verified_webhook_setup(require_key_fetch: false)

    token = JWT.encode(
      { iat: Time.current.to_i, request_body_sha256: Digest::SHA256.hexdigest(body) },
      "not-a-real-secret", "HS256", { "kid" => jwk.kid }
    )

    assert_raises JWT::VerificationError, JWT::DecodeError do
      provider.validate_webhook!(token, body)
    end
  end

  test "accepts a token with an expired exp while the iat age check governs freshness" do
    provider, jwk, key, body = verified_webhook_setup
    token = JWT.encode(
      { iat: Time.current.to_i, exp: 1.minute.ago.to_i, request_body_sha256: Digest::SHA256.hexdigest(body) },
      key, "ES256", { "kid" => jwk.kid }
    )

    assert_nothing_raised { provider.validate_webhook!(token, body) }
  end

  private
    def expect_transaction_page(cursor, pages)
      @plaid.client.expects(:transactions_sync).with do |request|
        request.access_token == "access-token" && request.cursor == cursor &&
          request.count == 500 && request.options == { include_original_description: true, days_requested: Provider::Plaid::MAX_HISTORY_DAYS }
      end.in_sequence(pages)
    end

    def transaction_page(cursor, has_more: false, prefix: "kept")
      OpenStruct.new(
        added: [ "#{prefix}-added" ],
        modified: [ "#{prefix}-modified" ],
        removed: [ "#{prefix}-removed" ],
        has_more: has_more,
        next_cursor: cursor
      )
    end

    def transaction_mutation_error
      Plaid::ApiError.new(
        code: 400,
        response_body: { error_code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" }.to_json
      )
    end

    def expect_transaction_restart(retry_count)
      DebugLogEntry.expects(:capture).with(
        category: "provider_sync",
        level: "info",
        message: "Restarting Plaid transaction pagination after data changed",
        source: "Provider::PlaidSandbox",
        provider_key: "plaid",
        metadata: { error_code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", retry_count: retry_count }
      )
    end

    # Pins the webhook verification contract that the jwt gem bump (2.10.3 ->
    # 3.3.0) rides on: JWKS built from the key Plaid publishes for the token's
    # kid, ES256 decode with expiration skipped in favor of the iat age check,
    # and the request-body SHA-256 comparison.
    def verified_webhook_setup(require_key_fetch: true)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      jwk = JWT::JWK.new(key, { use: "sig" })
      body = '{"webhook_type":"TRANSACTIONS","webhook_code":"INITIAL_UPDATE"}'

      client = mock
      if require_key_fetch
        client.expects(:webhook_verification_key_get).with do |request|
          request.is_a?(Plaid::WebhookVerificationKeyGetRequest) && request.key_id == jwk.kid
        end.returns(Struct.new(:key).new(jwk.export))
      else
        # An unsupported algorithm is rejected at decode time, before any
        # key fetch happens.
        client.stubs(:webhook_verification_key_get)
      end

      config = Plaid::Configuration.new
      config.server_index = Plaid::Configuration::Environment["sandbox"]
      provider = Provider::Plaid.new(config)
      provider.instance_variable_set(:@client, client)

      [ provider, jwk, key, body ]
    end

    def get_access_token
      VCR.use_cassette("plaid/access_token") do
        public_token = @plaid.create_public_token
        exchange_response = @plaid.exchange_public_token(public_token)
        exchange_response.access_token
      end
    end
end
