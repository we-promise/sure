module FinancekitTestHelper
  def financekit_setup
    travel_to Time.utc(2026, 9, 10, 12)
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @family = @user.family
    @device_key = OpenSSL::PKey::EC.generate("prime256v1")
    @server_key = OpenSSL::PKey::RSA.generate(3072)
    @receipt_key = OpenSSL::PKey::EC.generate("prime256v1")
    Financekit.stubs(:enabled?).returns(true)
    Financekit::Crypto.stubs(:encryption_key).returns(@server_key)
    Financekit::Crypto.stubs(:receipt_key).returns(@receipt_key)
    Financekit::Crypto.stubs(:server_id).returns("sure-test-server")
    @source_id = "11111111-1111-4111-8111-111111111111"
    @transaction_id = "22222222-2222-4222-8222-222222222222"
    @device_jwk = JWT::JWK.new(@device_key).export.slice(:kty, :crv, :x, :y).stringify_keys
    @enrollment = { "enrollment_id" => SecureRandom.uuid, "device_public_key" => @device_jwk,
      "protocol" => 1, "consent" => { "version" => 1, "upload_authorized" => true,
        "enrichment_acknowledged" => true, "source_ids" => [ @source_id ] } }
    @item = Financekit::Enrollment.create!(@user, @enrollment)
    @mapping_input = { "expected_version" => 0, "action" => "create", "name" => "Test Wallet",
      "currency" => "USD", "accountable_type" => "Depository", "subtype" => "checking",
      "ledger_timezone" => "America/Los_Angeles", "booked_balance" => money("125.00", "credit"), "observed_at" => Time.current.iso8601 }
    @source = FinancekitAccount.map!(@item, @source_id, @mapping_input)
  end

  def money(amount = "12.34", direction = "debit", currency = "USD")
    { "amount" => amount, "currency" => currency, "credit_debit" => direction }
  end

  def financekit_payload
    now = Time.current.iso8601
    { "captured_at" => now,
      "history" => { "kind" => "snapshot", "snapshot_id" => "33333333-3333-4333-8333-333333333333",
        "start_at" => "2026-01-01T00:00:00Z", "end_at" => now, "complete" => true },
      "accounts" => [ { "source_id" => @source_id, "mapping_version" => 1, "observed_at" => now,
        "booked_balance" => money("112.66", "credit"), "available_balance" => money("100.32", "credit") } ],
      "transactions" => [ money.merge("source_id" => @transaction_id, "account_id" => @source_id,
        "mapping_version" => 1, "transacted_at" => "2026-09-01T06:00:00Z", "posted_at" => "2026-09-01T07:00:00Z",
        "status" => "booked", "type" => "purchase", "merchant" => "Synthetic shop") ], "tombstones" => [] }
  end

  def financekit_envelope(payload = financekit_payload, sequence: 1, previous: nil, batch_id: SecureRandom.uuid, generation: @item.generation)
    jwe = JSON::JWE.new(JSON.generate(payload))
    jwe.alg = :"RSA-OAEP"
    jwe.enc = :A256GCM
    ciphertext = jwe.encrypt!(@server_key.public_key).to_s
    claims = { "aud" => "sure-test-server", "protocol" => 1, "connection_id" => @item.id,
      "generation" => generation, "batch_id" => batch_id, "sequence" => sequence,
      "previous_digest" => previous, "ciphertext" => ciphertext, "digest" => Digest::SHA256.hexdigest(ciphertext) }
    JWT.encode(claims, @device_key, "ES256", { typ: "sure-financekit+jwt" })
  end
end
