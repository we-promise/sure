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

  test "ignore! keeps the account's identity but drops what was fetched for it" do
    @account.update!(current_balance: 1234.56, raw_payload: { "uid" => "uid_1", "iban" => "FR7612345" },
      raw_transactions_payload: [ { "transaction_id" => "t1" } ])

    assert @account.ignore!

    @account.reload
    assert @account.ignored?
    assert_equal "hash_abc123", @account.uid
    assert_equal "Mon compte", @account.name
    assert_nil @account.current_balance
    assert_nil @account.raw_payload
    assert_nil @account.raw_transactions_payload
  end

  test "ignore! refuses an account that is linked to a Sure account" do
    @account.update!(current_balance: 10)
    AccountProvider.create!(account: accounts(:depository), provider: @account)

    assert_not @account.ignore!
    assert_not @account.reload.ignored?
    assert_equal 10, @account.current_balance
  end

  test "needs_setup leaves out linked and ignored accounts" do
    linked = EnableBankingAccount.create!(enable_banking_item: @item, name: "Linked", uid: "hash_linked", currency: "EUR")
    AccountProvider.create!(account: accounts(:depository), provider: linked)

    assert_equal [ @account ], @item.enable_banking_accounts.needs_setup.to_a

    @account.ignore!
    assert_empty @item.enable_banking_accounts.needs_setup
  end

  test "snapshot writers skip an account ignored after it was loaded" do
    stale = EnableBankingAccount.find(@account.id)
    @account.ignore!

    assert_no_changes -> { @account.reload.attributes } do
      assert_not stale.upsert_enable_banking_snapshot!(uid: "uid_1", identification_hash: "hash_abc123", name: "Renamed", currency: "EUR")
      assert_not stale.upsert_enable_banking_transactions_snapshot!([ { "transaction_id" => "t1" } ])
    end
  end
end
