require "test_helper"

class Provider::Truelayer::AdapterTest < ActiveSupport::TestCase
  setup do
    @connection = provider_connections(:monzo_connection)
    @adapter    = Provider::Truelayer::Adapter.new(@connection)
  end

  test "fetch_accounts returns normalised array combining accounts and cards" do
    mock_client = mock
    mock_client.expects(:get_accounts).returns([ {
      "account_id" => "acc_1", "display_name" => "Current",
      "account_type" => "TRANSACTION", "currency" => "GBP"
    } ])
    mock_client.expects(:get_cards).returns([ {
      "account_id" => "card_1", "card_type" => "VISA",
      "currency" => "GBP"
    } ])
    @adapter.stubs(:client).returns(mock_client)

    results = @adapter.fetch_accounts("tok")
    assert_not results[:partial]
    accounts = results[:accounts]
    assert_equal 2, accounts.length

    account = accounts.find { |r| r[:external_id] == "acc_1" }
    assert_equal "Current", account[:name]
    assert_equal "depository", account[:type]
    assert_equal "checking", account[:subtype]

    card = accounts.find { |r| r[:external_id] == "card_1" }
    assert_equal "credit", card[:type]
    assert_equal "credit_card", card[:subtype]
  end

  test "fetch_transactions combines settled and pending" do
    mock_client = mock
    mock_client.expects(:get_transactions).returns([ {
      "transaction_id" => "tx_1", "amount" => -10.5,
      "currency" => "GBP", "timestamp" => "2026-05-01T10:00:00Z",
      "description" => "Coffee"
    } ])
    mock_client.expects(:get_pending_transactions).returns([ {
      "transaction_id" => "tx_2", "amount" => -5.0,
      "currency" => "GBP", "timestamp" => "2026-05-02T10:00:00Z",
      "description" => "Lunch"
    } ])
    @adapter.stubs(:client).returns(mock_client)

    pa = provider_accounts(:monzo_current)
    txns = @adapter.fetch_transactions("tok", pa)

    assert_equal 2, txns.length
    settled = txns.find { |t| t[:external_id] == "tx_1" }
    pending = txns.find { |t| t[:external_id] == "tx_2" }
    assert_not settled[:pending]
    assert pending[:pending]
    assert_equal BigDecimal("-10.5"), settled[:amount]
    assert_equal Date.new(2026, 5, 1), settled[:date]
  end

  test "fetch_balance calls card endpoint when external_type is credit" do
    card_pa = provider_accounts(:monzo_current).tap { |pa| pa.external_type = "credit" }
    mock_client = mock
    mock_client.expects(:get_balance).with(card_pa.external_id, kind: "card").returns({})
    @adapter.stubs(:client).returns(mock_client)
    @adapter.fetch_balance("tok", card_pa)
  end

  test "fetch_transactions uses card kind when external_type is credit" do
    card_pa = provider_accounts(:monzo_current).tap { |pa| pa.external_type = "credit" }
    mock_client = mock
    mock_client.expects(:get_transactions)
               .with(card_pa.external_id, has_entries(kind: "card"))
               .returns([])
    mock_client.expects(:get_pending_transactions)
               .with(card_pa.external_id, kind: "card")
               .returns([])
    @adapter.stubs(:client).returns(mock_client)
    @adapter.fetch_transactions("tok", card_pa)
  end

  test "fetch_consent_expiry returns nil gracefully on API error" do
    Provider::Truelayer.any_instance.stubs(:me).raises(StandardError)
    assert_nil @adapter.fetch_consent_expiry(@connection, "tok")
  end

  test "fetch_consent_expiry parses consent_expires_at from me response" do
    expiry = 90.days.from_now
    Provider::Truelayer.any_instance.stubs(:me).returns(
      "results" => [ { "consent_expires_at" => expiry.iso8601 } ]
    )
    result = @adapter.fetch_consent_expiry(@connection, "tok")
    assert_in_delta expiry.to_i, result.to_i, 2
  end

  test "ConnectionRegistry.config_for returns a Truelayer::Adapter instance" do
    adapter = Provider::ConnectionRegistry.config_for("truelayer")
    assert_instance_of Provider::Truelayer::Adapter, adapter
  end

  test "authorize_url builds correct TrueLayer production OAuth URL" do
    adapter = Provider::Truelayer::Adapter.new(nil)
    url = adapter.authorize_url(
      client_id:    "cid",
      redirect_uri: "https://example.com/cb",
      state:        "conn_uuid",
      scope:        %w[accounts balance]
    )
    assert_match "https://auth.truelayer.com/", url
    assert_match "client_id=cid", url
    assert_match "scope=accounts+balance", url
    assert_match "uk-ob-all", url
  end

  test "authorize_url uses sandbox auth URL when sandbox: true" do
    adapter = Provider::Truelayer::Adapter.new(nil)
    url = adapter.authorize_url(
      client_id: "cid", redirect_uri: "https://example.com/cb",
      state: "s", scope: %w[accounts], sandbox: true
    )
    assert_match "auth.truelayer-sandbox.com", url
    assert_match "providers=mock", url
  end

  test "fetch_accounts marks partial: true and returns only cards when accounts endpoint errors" do
    mock_client = mock
    mock_client.expects(:get_accounts).raises(Provider::Truelayer::Error, "Endpoint not supported by this bank")
    mock_client.expects(:get_cards).returns([ {
      "account_id" => "card_1", "card_type" => "VISA", "currency" => "GBP"
    } ])
    @adapter.stubs(:client).returns(mock_client)

    results = @adapter.fetch_accounts("tok")
    assert results[:partial]
    assert_equal 1, results[:accounts].length
    assert_equal "credit", results[:accounts].first[:type]
  end

  test "fetch_accounts marks partial: true and returns only accounts when cards endpoint errors" do
    mock_client = mock
    mock_client.expects(:get_accounts).returns([ {
      "account_id" => "acc_1", "display_name" => "Current",
      "account_type" => "TRANSACTION", "currency" => "GBP"
    } ])
    mock_client.expects(:get_cards).raises(Provider::Truelayer::Error, "Endpoint not supported by this bank")
    @adapter.stubs(:client).returns(mock_client)

    results = @adapter.fetch_accounts("tok")
    assert results[:partial]
    assert_equal 1, results[:accounts].length
    assert_equal "depository", results[:accounts].first[:type]
  end

  test "fetch_accounts normalises card name from card_type fallback" do
    mock_client = mock
    mock_client.expects(:get_accounts).returns([])
    mock_client.expects(:get_cards).returns([ {
      "account_id" => "card_1", "card_type" => "VISA", "currency" => "GBP"
    } ])
    @adapter.stubs(:client).returns(mock_client)

    card = @adapter.fetch_accounts("tok")[:accounts].first
    assert_equal "VISA", card[:name]
  end

  # normalise_transactions name extraction

  test "name uses merchant_name when present" do
    t = normalise_one("merchant_name" => "Starbucks", "description" => "SBX*LONDON")
    assert_equal "Starbucks", t[:name]
  end

  test "name falls back to meta counter_party_preferred_name" do
    t = normalise_one("meta" => { "counter_party_preferred_name" => "James Kapherr" })
    assert_equal "James Kapherr", t[:name]
  end

  test "name falls back to meta counterparty_name" do
    t = normalise_one("meta" => { "counterparty_name" => "Alice Smith" })
    assert_equal "Alice Smith", t[:name]
  end

  test "name falls back to transaction_category for transfers" do
    t = normalise_one("description" => "R2391", "transaction_category" => "TRANSFER")
    assert_equal "Bank Transfer", t[:name]
  end

  test "name uses humanized description when not a bare reference code" do
    t = normalise_one("description" => "TESCO STORES 001")
    assert_equal "TESCO STORES 001", t[:name]
  end

  test "bare reference codes are rejected as names" do
    t = normalise_one("description" => "FP12345678", "transaction_category" => "TRANSFER")
    assert_equal "Bank Transfer", t[:name]
  end

  test "name falls back to TrueLayer Transaction as last resort" do
    t = normalise_one({})
    assert_equal "TrueLayer Transaction", t[:name]
  end

  test "merchant_name set from raw merchant_name" do
    t = normalise_one("merchant_name" => "Pret")
    assert_equal "Pret", t[:merchant_name]
  end

  test "merchant_name set from meta when no merchant_name" do
    t = normalise_one("meta" => { "counter_party_preferred_name" => "Will Wilson" })
    assert_equal "Will Wilson", t[:merchant_name]
  end

  test "merchant_name is nil when only category fallback applies" do
    t = normalise_one("description" => "R2391", "transaction_category" => "TRANSFER")
    assert_nil t[:merchant_name]
  end

  test "notes always carries raw description even when merchant_name present" do
    t = normalise_one("merchant_name" => "Starbucks", "description" => "SBX*LONDON BRIDGE")
    assert_equal "SBX*LONDON BRIDGE", t[:notes]
  end

  test "meta is stored in normalised hash" do
    meta = { "counter_party_preferred_name" => "Jane", "bank_transaction_id" => "bti_1" }
    t = normalise_one("meta" => meta)
    assert_equal meta, t[:meta]
  end

  test "transaction_category is passed through" do
    t = normalise_one("transaction_category" => "TRANSFER")
    assert_equal "TRANSFER", t[:transaction_category]
  end

  private

    def normalise_one(overrides = {})
      base = {
        "transaction_id" => "tx_base",
        "timestamp"      => "2026-05-01T10:00:00Z",
        "amount"         => -10.0,
        "currency"       => "GBP"
      }
      @adapter.send(:normalise_transactions, [ base.merge(overrides) ], pending: false).first
    end
end
