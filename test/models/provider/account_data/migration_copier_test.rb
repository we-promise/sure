require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::MigrationCopierTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Copier = Provider::AccountData::MigrationCopier
  Manifest = Provider::AccountData::MigrationManifest

  test "bounded resumable copy retains financial identities and encrypted lossless source snapshots" do
    with_provider_encryption do
      item = create_up_item(raw_payload: { "unicode" => "銀行" * 2500 })
      first = create_up_account(item, account_id: "up-first", current_balance: BigDecimal("1.2345"),
        raw_payload: nil, raw_transactions_payload: [])
      second = create_up_account(item, account_id: "up-second", current_balance: 0, ignored: true)
      financial = accounts(:depository)
      link = AccountProvider.create!(account: financial, provider: first)
      financial_before = financial.attributes
      entry_ids = financial.entries.order(:id).pluck(:id)
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id, batch_size: 1, chunk_bytes: 1024)

      assert_equal "copying", copier.run.state
      assert_equal 1, copier.control.provider_connection.external_accounts.count
      assert_equal "shadow", finish_copy(copier).state

      connection = copier.control.provider_connection.reload
      external = mapped_account(copier, first)
      assert connection.disabled?
      assert_not_includes ProviderConnection.syncable, connection
      assert_equal "private-up-token", connection.credentials.fetch("access_token")
      assert_provider_column_encrypted(connection, :credentials, "private-up-token")
      assert_equal BigDecimal("1.2345"), external.current_balance
      assert mapped_account(copier, second).ignored?
      assert_equal 0, mapped_account(copier, second).current_balance
      assert_equal link.id, external.account_provider.id
      assert_equal financial.id, external.account.id
      assert_equal "UpAccount", link.reload.provider_type
      assert_equal first.id, link.provider_id
      assert_equal financial_before, financial.reload.attributes
      assert_equal entry_ids, financial.entries.order(:id).pluck(:id)

      snapshot = copier.snapshot_for(account_mapping(copier, first))
      assert_nil snapshot.fetch("attributes").fetch("raw_payload")
      assert_equal [], snapshot.fetch("attributes").fetch("raw_transactions_payload")
      assert_equal false, snapshot.fetch("attributes").fetch("ignored")
      assert_equal 4, snapshot.fetch("columns").fetch("current_balance").fetch("scale")
      connection_mapping = copier.control.provider_migration_mappings.find_by!(role: "connection")
      assert_equal item.read_attribute(:raw_payload), copier.snapshot_for(connection_mapping).fetch("attributes").fetch("raw_payload")
      assert connection.ingestion_batches.where(external_account_id: nil).count > 1
      connection.ingestion_batches.each do |batch|
        assert_equal "migration", batch.origin_kind
        assert_equal "unknown", batch.mode
        assert_not batch.complete?
        assert_nil batch.sync_id
        assert_provider_column_encrypted(batch, :payload, "private-up-token")
      end
      assert_equal false, copier.control.audit_results.fetch("source_quiesced")
      assert_equal true, copier.control.audit_results.fetch("requires_cutover_reverification")

      original_counts = [ ProviderConnection.count, ExternalAccount.count, ProviderMigrationMapping.count, IngestionBatch.count, AccountProvider.count ]
      copier.run
      finish_copy(copier)
      assert_equal original_counts, [ ProviderConnection.count, ExternalAccount.count, ProviderMigrationMapping.count, IngestionBatch.count, AccountProvider.count ]
    end
  end

  test "Coinbase unresolved identities retain exact asset quantities without inventing valuation" do
    with_provider_encryption do
      item = CoinbaseItem.create!(family: families(:dylan_family), name: "Wallets", api_key: "key", api_secret: "secret")
      amount = BigDecimal("1234567890123456.123456789012345678")
      source = item.coinbase_accounts.create!(name: "Wallet", currency: "USD", account_id: nil, current_balance: amount)
      copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id)

      copier.run
      finish_copy(copier)

      external = mapped_account(copier, source)
      assert_nil external.current_balance
      assert_nil external.currency
      assert_equal amount.to_s("F"), external.metadata.dig("asset", "quantity")
      assert_equal "USD", external.metadata.dig("asset", "code")
      assert_equal "unavailable", external.metadata.dig("valuation", "origin")
      assert_nil external.external_id
      assert external.identity_unresolved?
      assert_equal amount, copier.snapshot_for(account_mapping(copier, source)).fetch("attributes").fetch("current_balance")
    end
  end

  test "Coinbase native fiat value is separate from crypto units and preserves financial UUIDs and typed archives" do
    with_provider_encryption do
      item = CoinbaseItem.create!(family: families(:dylan_family), name: "Wallets", api_key: "key", api_secret: "secret")
      quantity = BigDecimal("0.000000000000000148")
      raw = { "currency" => { "code" => "BTC", "name" => "Bitcoin", "type" => "crypto" },
        "native_balance" => { "amount" => "9.123456789012345678", "currency" => "EUR" }, "private_owner" => "private-wallet-owner" }
      source = item.coinbase_accounts.create!(name: "Bitcoin", currency: "BTC", account_id: "wallet_1",
        current_balance: quantity, account_type: "vault", raw_payload: raw)
      financial = accounts(:depository)
      link = AccountProvider.create!(account: financial, provider: source)
      financial_before = financial.attributes
      entry_ids = financial.entries.order(:id).pluck(:id)
      copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id)

      copier.run
      finish_copy(copier)

      external = mapped_account(copier, source)
      assert_equal BigDecimal("9.123456789012345678"), external.current_balance
      assert_equal "EUR", external.currency
      assert_equal "Crypto", external.account_type
      assert_nil external.cash_balance if financial.currency != "EUR"
      assert_equal quantity.to_s("F"), external.metadata.dig("asset", "quantity")
      assert_equal "BTC", external.metadata.dig("asset", "code")
      assert_equal "Bitcoin", external.metadata.dig("asset", "name")
      assert_equal "vault", external.metadata["wallet_type"]
      assert_equal "legacy_native_balance", external.metadata.dig("valuation", "origin")
      assert_equal financial.id, external.account.id
      assert_equal link.id, external.account_provider.id
      assert_equal financial_before, financial.reload.attributes
      assert_equal entry_ids, financial.entries.order(:id).pluck(:id)
      snapshot = copier.snapshot_for(account_mapping(copier, source))
      assert_equal quantity, snapshot.fetch("attributes").fetch("current_balance")
      assert_equal "BTC", snapshot.fetch("attributes").fetch("currency")
      assert_equal raw, snapshot.fetch("attributes").fetch("raw_payload")
      refute_includes external.metadata.to_json, "private-wallet-owner"
    end
  end

  test "Coinbase missing native value uses an explicit linked fiat snapshot without changing its unit" do
    with_provider_encryption do
      item = CoinbaseItem.create!(family: families(:dylan_family), name: "Wallets", api_key: "key", api_secret: "secret")
      source = item.coinbase_accounts.create!(name: "Bitcoin", currency: "BTC", account_id: "wallet_1", current_balance: BigDecimal("0.5"),
        raw_payload: { "native_balance" => { "currency" => "EUR" } })
      financial = accounts(:depository)
      financial.update!(balance: BigDecimal("987.65"), cash_balance: BigDecimal("0"), currency: "USD")
      AccountProvider.create!(account: financial, provider: source)
      copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id)

      copier.run
      finish_copy(copier)

      external = mapped_account(copier, source)
      assert_equal BigDecimal("987.65"), external.current_balance
      assert_equal "USD", external.currency
      assert_equal BigDecimal("0"), external.cash_balance
      assert_equal "0.5", external.metadata.dig("asset", "quantity")
      assert_equal "linked_account_snapshot", external.metadata.dig("valuation", "origin")
      assert_equal true, external.metadata.dig("valuation", "requires_provider_refresh")
      assert_nil external.metadata.dig("valuation", "native_amount")
    end
  end

  test "Coinbase copy preserves nil versus explicit zero native valuation" do
    with_provider_encryption do
      item = CoinbaseItem.create!(family: families(:dylan_family), name: "Wallets", api_key: "key", api_secret: "secret")
      missing = item.coinbase_accounts.create!(name: "Empty unknown", currency: "BTC", account_id: "missing", current_balance: 0)
      zero = item.coinbase_accounts.create!(name: "Empty valued", currency: "ETH", account_id: "zero", current_balance: 0,
        raw_payload: { "native_balance" => { "amount" => "0", "currency" => "GBP" } })
      copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id)

      copier.run
      finish_copy(copier)

      assert_nil mapped_account(copier, missing).current_balance
      assert_nil mapped_account(copier, missing).currency
      assert_equal false, mapped_account(copier, missing).metadata["balance_provided"]
      assert_equal BigDecimal("0"), mapped_account(copier, zero).current_balance
      assert_equal "GBP", mapped_account(copier, zero).currency
      assert_equal true, mapped_account(copier, zero).metadata["balance_provided"]
    end
  end

  test "Coinbase linked fallback changes cannot pass verification of a different monetary projection" do
    with_provider_encryption do
      item = CoinbaseItem.create!(family: families(:dylan_family), name: "Wallets", api_key: "key", api_secret: "secret")
      source = item.coinbase_accounts.create!(name: "Bitcoin", currency: "BTC", account_id: "wallet_1", current_balance: BigDecimal("0.5"))
      financial = accounts(:depository)
      AccountProvider.create!(account: financial, provider: source)
      copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id)
      copier.run
      financial.update!(balance: financial.balance + 1)

      assert_raises(Copier::Conflict) { copier.run }
      assert copier.control.reload.failed?
      assert copier.control.provider_connection.disabled?
    end
  end

  test "source changes restart comparison and update the existing target without duplicating financial records" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item, current_balance: 1)
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)
      copier.run
      target_id = mapped_account(copier, source).id
      source.update!(current_balance: 2)

      assert_raises(Copier::SourceChanged) { copier.run }
      assert_equal "copy", copier.control.reload.high_water_mark.fetch("phase")
      assert copier.control.copying?
      assert_nil copier.control.lease_owner
      finish_copy(copier)

      assert_equal target_id, mapped_account(copier, source).id
      assert_equal 2, mapped_account(copier, source).current_balance
      assert_equal 1, copier.control.provider_connection.external_accounts.count
      assert_equal 0, copier.control.provider_connection.account_providers.count
    end
  end

  test "unknown account columns fail without partial account links or leaking credentials" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item)
      link = AccountProvider.create!(account: accounts(:depository), provider: source)
      UpAccount.stubs(:columns_hash).returns(UpAccount.columns_hash.merge("new_secret" => UpAccount.columns_hash.fetch("name")))
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)

      error = assert_raises(Manifest::InvalidSource) { copier.run }

      refute_includes error.message, "private-up-token"
      assert copier.control.reload.failed?
      assert copier.control.provider_connection.disabled?
      assert_nil link.reload.external_account_id
      assert_empty copier.control.provider_connection.external_accounts
    end
  end

  test "undecoded legacy ciphertext cannot be copied as a plaintext credential" do
    with_provider_encryption do
      ciphertext = ActiveRecord::Encryption.encryptor.encrypt("private-legacy-token")
      item = create_up_item(access_token: ciphertext)
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)

      error = assert_raises(Manifest::InvalidSource) { copier.run }

      refute_includes error.message, "private-legacy-token"
      assert_nil copier.control.reload.provider_connection_id
      assert copier.control.failed?
    end
  end

  test "existing direct and join links must agree and source transactions roll back on conflict" do
    with_provider_encryption do
      source = plaid_accounts(:one)
      link = AccountProvider.create!(account: accounts(:depository), provider: source)
      copier = Copier.new(provider_key: "plaid", legacy_item_id: source.plaid_item_id)

      assert_raises(Copier::Conflict) { copier.run }

      assert copier.control.reload.failed?
      assert_nil link.reload.external_account_id
      assert_equal source.id, accounts(:connected).reload.plaid_account_id
      assert_empty copier.control.provider_connection.external_accounts
      assert_equal 0, copier.control.provider_migration_mappings.where(role: "external_account").count
    end
  end

  test "direct-only Plaid link keeps its original financial account and shared provider key" do
    with_provider_encryption do
      source = plaid_accounts(:one)
      financial = accounts(:connected)
      copier = Copier.new(provider_key: "plaid_eu", legacy_item_id: source.plaid_item_id)

      copier.run
      finish_copy(copier)

      external = mapped_account(copier, source)
      assert_equal financial.id, external.account.id
      assert_equal source.id, financial.reload.plaid_account_id
      assert_equal "plaid", external.account_provider.provider_key
      assert_equal "PlaidAccount", external.account_provider.provider_type
    end
  end

  test "Enable Banking separates application credentials from renewable authorization without changing stable account identity" do
    with_provider_encryption do
      item = EnableBankingItem.create!(family: families(:dylan_family), name: "Application", country_code: "FI",
        application_id: "app-id", client_certificate: "private-certificate", authorization_id: "grant-id",
        session_id: "private-session", session_expires_at: 1.day.from_now.change(usec: 0),
        aspsp_id: "bank-fi", aspsp_name: "Example Bank", last_psu_ip: "192.0.2.10")
      source = item.enable_banking_accounts.create!(uid: "stable-account-hash", account_id: SecureRandom.uuid,
        name: "Everyday", currency: "EUR", iban: "private-iban", identification_hashes: [ "stable-account-hash" ])
      copier = Copier.new(provider_key: "enable_banking", legacy_item_id: item.id)

      copier.run
      finish_copy(copier)

      connection = copier.control.provider_connection
      authorization = connection.provider_authorizations.sole
      external = mapped_account(copier, source)
      assert_equal "app-id", connection.credentials.fetch("application_id")
      assert_equal "private-certificate", connection.credentials.fetch("client_certificate")
      assert_not connection.credentials.key?("session_id")
      assert_equal "private-session", authorization.credentials.fetch("session_id")
      assert_equal "192.0.2.10", authorization.credentials.fetch("last_psu_ip")
      assert_equal "bank-fi", authorization.institution_metadata.fetch("aspsp_id")
      assert_equal item.session_expires_at, authorization.expires_at
      assert_equal "stable-account-hash", external.external_id
      assert_equal "private-iban", external.sensitive_details.fetch("iban")
      assert_equal [ external.id ], authorization.external_accounts.pluck(:id)
      assert_provider_column_encrypted(authorization, :credentials, "private-session")
      assert_provider_column_encrypted(external, :sensitive_details, "private-iban")
      refute_includes connection.metadata.to_json, "private-certificate"
      refute_includes connection.metadata.to_json, "192.0.2.10"
    end
  end

  test "tampered chunks prevent a verified shadow" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item)
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)
      copier.run
      batch = copier.control.provider_connection.ingestion_batches.find_by!(external_account: mapped_account(copier, source))
      payload = batch.payload.merge("data" => Base64.strict_encode64("corrupt source row"))
      batch.update_columns(payload: payload)

      assert_raises(Copier::Conflict) { copier.run }
      assert copier.control.reload.failed?
      assert copier.control.provider_connection.disabled?
      assert_nil account_mapping(copier, source).verified_at
    end
  end

  test "active leases and activation states reject copy without changing existing control" do
    with_provider_encryption do
      item = create_up_item
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)
      copier.run
      control = copier.control
      control.update!(lease_owner: "another-copier", lease_expires_at: 1.minute.from_now)

      assert_raises(Copier::Busy) { copier.run }
      assert_equal "another-copier", control.reload.lease_owner
      control.update!(lease_owner: nil, lease_expires_at: nil, state: "active")
      assert_raises(Copier::Conflict) { copier.run }
      assert control.reload.active?
    end
  end

  test "bounded snapshot reconstruction preserves exact unicode typed values and accepts its exact decoded budget" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item, raw_payload: { "private" => "銀行" * 500 }, current_balance: BigDecimal("1.2345"))
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id, chunk_bytes: 1024)
      finish_copy(copier)
      mapping = account_mapping(copier, source)
      expected = copier.snapshot_for(mapping)
      size = Provider::AccountData::MigrationValue.dump(expected).bytesize
      assert_equal expected, copier.snapshot_for(mapping, max_bytes: size, max_chunks: 1024)
      assert_raises(Copier::Conflict) { copier.snapshot_for(mapping, max_bytes: size - 1, max_chunks: 1024) }
    end
  end

  test "snapshot chunk inventory is bounded before encrypted payloads are loaded" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item, raw_payload: { "private" => "owned-source-data" * 500 })
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id, chunk_bytes: 1024)
      finish_copy(copier)
      mapping = account_mapping(copier, source)
      IngestionBatch.any_instance.expects(:payload).never
      assert_raises(Copier::Conflict) { copier.snapshot_for(mapping, max_bytes: 32.megabytes, max_chunks: 1) }
    end
  end

  test "snapshot read limits reject malformed values without changing stored evidence" do
    with_provider_encryption do
      item = create_up_item
      source = create_up_account(item)
      copier = Copier.new(provider_key: "up", legacy_item_id: item.id)
      finish_copy(copier)
      mapping = account_mapping(copier, source)
      [ 0, -1, 1.5, false ].each do |limit|
        assert_raises(ArgumentError) { copier.snapshot_for(mapping, max_bytes: limit) }
        assert_raises(ArgumentError) { copier.snapshot_for(mapping, max_chunks: limit) }
      end
      assert copier.snapshot_for(mapping).present?
      assert mapping.reload.verified_at
    end
  end

  private
    def create_up_item(**attributes)
      UpItem.create!({ family: families(:dylan_family), name: "Up", access_token: "private-up-token" }.merge(attributes))
    end

    def create_up_account(item, **attributes)
      item.up_accounts.create!({ account_id: SecureRandom.uuid, name: "Everyday", currency: "USD" }.merge(attributes))
    end

    def finish_copy(copier)
      20.times do
        return copier.control.reload if copier.control&.reload&.shadow?
        copier.run
      end
      flunk "Migration did not reach shadow within the expected bounded calls"
    end

    def account_mapping(copier, source)
      copier.control.provider_migration_mappings.find_by!(role: "external_account", legacy_type: source.class.name, legacy_id: source.id)
    end

    def mapped_account(copier, source)
      account_mapping(copier, source).target.reload
    end
end
