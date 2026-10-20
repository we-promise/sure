require "test_helper"

class EnableBankingAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "app_id",
      client_certificate: "cert"
    )
    @account = EnableBankingAccount.create!(
      enable_banking_item: @item,
      name: "Mon compte",
      uid: "hash_abc123",
      currency: "EUR"
    )
  end

  test "balance observations are encrypted at rest when encryption is configured" do
    skip "Encryption not configured" unless EnableBankingAccount.encryption_ready?

    snapshot = { "status" => "complete", "fetched_at" => Time.current.iso8601,
                 "balances" => { "booked" => { "amount" => "123.45", "currency" => "EUR", "source_type" => "CLBD" } } }
    @account.update!(balance_snapshot: snapshot)
    stored = EnableBankingAccount.connection.select_value(
      EnableBankingAccount.sanitize_sql_array([ "SELECT balance_snapshot FROM enable_banking_accounts WHERE id = ?", @account.id ])
    )

    assert_includes EnableBankingAccount.encrypted_attributes.map(&:to_s), "balance_snapshot"
    assert_not_includes stored, "123.45"
    assert_equal snapshot, @account.reload.balance_snapshot
  end

  # suggested_account_type / suggested_subtype mapping
  test "suggests Depository checking for CACC" do
    @account.update!(account_type: "CACC")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype
  end

  test "suggests Depository savings for SVGS" do
    @account.update!(account_type: "SVGS")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype
  end

  test "suggests CreditCard for CARD" do
    @account.update!(account_type: "CARD")
    assert_equal "CreditCard", @account.suggested_account_type
    assert_equal "credit_card", @account.suggested_subtype
  end

  test "suggests Loan for LOAN" do
    @account.update!(account_type: "LOAN")
    assert_equal "Loan", @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "suggests Loan mortgage for MORT" do
    @account.update!(account_type: "MORT")
    assert_equal "Loan", @account.suggested_account_type
    assert_equal "mortgage", @account.suggested_subtype
  end

  test "returns nil for OTHR" do
    @account.update!(account_type: "OTHR")
    assert_nil @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "suggests Depository savings for MOMA and ONDP" do
    @account.update!(account_type: "MOMA")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype

    @account.update!(account_type: "ONDP")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype
  end

  test "suggests Depository checking for NREX, TAXE, and TRAS" do
    @account.update!(account_type: "NREX")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype

    @account.update!(account_type: "TAXE")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype

    @account.update!(account_type: "TRAS")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype
  end

  test "returns nil when account_type is blank" do
    @account.update!(account_type: nil)
    assert_nil @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "is case insensitive for account type mapping" do
    @account.update!(account_type: "svgs")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype
  end

  # upsert_enable_banking_snapshot! stores new fields
  test "stores product from snapshot" do
    @account.upsert_enable_banking_snapshot!({
      uid: "hash_abc123",
      identification_hash: "hash_abc123",
      currency: "EUR",
      cash_account_type: "SVGS",
      product: "Livret A"
    })
    assert_equal "Livret A", @account.reload.product
  end

  test "stores identification_hashes from snapshot" do
    @account.upsert_enable_banking_snapshot!({
      uid: "uid_uuid_123",
      identification_hash: "hash_abc123",
      identification_hashes: [ "hash_abc123", "hash_old456" ],
      currency: "EUR",
      cash_account_type: "CACC"
    })
    reloaded_account = @account.reload
    assert_includes reloaded_account.identification_hashes, "hash_abc123"
    assert_includes reloaded_account.identification_hashes, "hash_old456"
  end

  test "stores credit_limit from snapshot" do
    @account.upsert_enable_banking_snapshot!({
      uid: "uid_uuid_123",
      identification_hash: "hash_abc123",
      currency: "EUR",
      cash_account_type: "CARD",
      credit_limit: { amount: "2000.00", currency: "EUR" }
    })
    assert_equal 2000.00, @account.reload.credit_limit.to_f
  end

  test "stores account_servicer bic in institution_metadata" do
    @account.upsert_enable_banking_snapshot!({
      uid: "uid_uuid_123",
      identification_hash: "hash_abc123",
      currency: "EUR",
      cash_account_type: "CACC",
      account_servicer: { bic_fi: "BOURFRPPXXX", name: "Boursobank" }
    })
    metadata = @account.reload.institution_metadata
    assert_equal "BOURFRPPXXX", metadata["bic"]
    assert_equal "Boursobank", metadata["servicer_name"]
  end

  test "stores empty identification_hashes when not in snapshot" do
    @account.upsert_enable_banking_snapshot!({
      uid: "uid_uuid_123",
      identification_hash: "hash_abc123",
      currency: "EUR",
      cash_account_type: "CACC"
    })
    assert_equal [], @account.reload.identification_hashes
  end
end
