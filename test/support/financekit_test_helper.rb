module FinancekitTestHelper
  def financekit_setup(user: users(:family_admin))
    travel_to Time.utc(2026, 9, 10, 12)
    @user = user
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @family = @user.family
    Financekit.stubs(:enabled?).returns(true)
    @source_id = "11111111-1111-4111-8111-111111111111"
    @transaction_id = "22222222-2222-4222-8222-222222222222"
    @enrollment = { "enrollment_id" => SecureRandom.uuid, "protocol" => 1,
      "consent" => { "version" => 1, "upload_authorized" => true,
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
end
