require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::MigrationConnectionInputsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier

  %w[trading212 trade_republic].each do |provider_key|
    test "#{provider_key} copies the source currency used by its native factory" do
      with_provider_encryption do
        family = families(:dylan_family)
        currency = family.currency == "EUR" ? "GBP" : "EUR"
        item = currency_item(provider_key, family: family, currency: currency)
        copier = Copier.new(provider_key: provider_key, legacy_item_id: item.id)
        connection = finish_copy(copier)

        assert_equal currency, connection.settings.fetch("currency")
        assert_equal currency, item_archive(copier).fetch("attributes").fetch("currency")
        context = { family_currency: family.currency, timezone: "UTC", observed_at: Time.utc(2026, 9, 15),
          environment: connection.environment, credential_store: mock("unused credential store"), external_accounts: [] }

        record = if provider_key == "trading212"
          context[:trading212_instrument_catalog] = Provider::AccountData::Trading212::InstrumentCatalog.build(
            connection: connection, observed_at: context.fetch(:observed_at))
          Provider::Trading212.expects(:new).with(api_key: "key", api_secret: "secret", environment: "demo")
            .returns(mock("unused Trading 212 client"))
          adapter = Provider::AccountData::Trading212.build(credentials: connection.credentials, settings: connection.settings, context: context)
          adapter.normalize_account(id: "brokerage", totalValue: "12.50", cash: { availableToTrade: "2.50" })
        else
          context[:trade_republic_retained_portfolio] = connection.with_lock do
            Provider::AccountData::TradeRepublic::RetainedPortfolio.build(connection: connection, observed_at: context.fetch(:observed_at))
          end
          Provider::TradeRepublicClient::IngestionClient.expects(:new).with(credential_store: context.fetch(:credential_store))
            .returns(mock("unused Trade Republic client"))
          adapter = Provider::AccountData::TradeRepublic.build(credentials: connection.credentials, settings: connection.settings, context: context)
          adapter.normalize_account({ securitiesAccountNumber: "portfolio" }, kind: "portfolio")
        end

        assert_equal currency, record[:currency]
        assert connection.disabled?
        assert_empty connection.syncs
      ensure
        cleanup_item_copy(item) if item
      end
    end
  end

  test "SnapTrade copied expiry triggers refresh before an expired access token is used" do
    with_provider_encryption do
      now = Time.utc(2026, 9, 15, 12)
      item = SnaptradeItem.create!(family: families(:dylan_family), name: "Brokerage",
        oauth_access_token: "old-access", oauth_refresh_token: "old-refresh",
        oauth_token_expires_at: Time.iso8601("2026-09-15T06:59:59.123456-05:00"),
        oauth_scope: "read", oauth_token_type: "Bearer", consumer_key: "retained-sdk-secret")
      copier = Copier.new(provider_key: "snaptrade", legacy_item_id: item.id)
      connection = finish_copy(copier)
      expiry = item.reload.read_attribute(:oauth_token_expires_at)

      assert_equal expiry.getutc.iso8601(9), connection.credentials.fetch("oauth_token_expires_at")
      assert_equal expiry, item_archive(copier).fetch("attributes").fetch("oauth_token_expires_at")
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "legacy_state")
      assert_equal expiry, Provider::AccountData::MigrationValue.decode(checkpoint.state.fetch("columns")).fetch("oauth_token_expires_at")
      assert_equal "read", connection.settings.fetch("oauth_scope")
      assert_provider_column_encrypted(connection, :credentials, "old-refresh")

      # Exercise the consumer with the copied values without granting this
      # disabled connection native credential ownership or changing its tokens.
      session = mock("credential session")
      session.expects(:credentials).returns(connection.credentials)
      session.expects(:refresh_pending?).returns(false)
      session.expects(:begin_refresh!)
      session.expects(:persist_credentials!).with do |values|
        values.fetch("oauth_access_token") == "new-access" &&
          values.fetch("oauth_refresh_token") == "new-refresh" &&
          values.fetch("oauth_token_expires_at") == (now + 3600).iso8601(9) &&
          values.fetch("oauth_scope") == "read" && values.fetch("oauth_token_type") == "Bearer" &&
          values.fetch("consumer_key") == "retained-sdk-secret"
      end
      store = mock("credential store")
      store.expects(:with_session_lock).yields(session)
      client = Provider::Snaptrade::IngestionClient.new(credential_store: store, oauth_client_id: "application-id", clock: -> { now })
      refresh = stub_request(:post, Provider::Snaptrade::TOKEN_URL)
        .with(body: { grant_type: "refresh_token", refresh_token: "old-refresh", client_id: "application-id" })
        .to_return(status: 200, body: '{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}')
      data = stub_request(:get, "https://api.snaptrade.com/accounts")
        .with(headers: { Authorization: "Bearer new-access" }).to_return(status: 200, body: "[]")

      assert_empty client.accounts_snapshot
      assert_requested refresh, times: 1
      assert_requested data, times: 1
      assert_not_requested :get, "https://api.snaptrade.com/accounts", headers: { Authorization: "Bearer old-access" }
      assert_equal "old-access", connection.reload.credentials.fetch("oauth_access_token")
      assert connection.disabled?
      assert_empty connection.syncs
    ensure
      cleanup_item_copy(item) if item
    end
  end

  test "SnapTrade unknown expiry remains unknown and does not become a sync watermark" do
    with_provider_encryption do
      item = SnaptradeItem.create!(family: families(:dylan_family), name: "Unknown expiry", oauth_access_token: "access")
      copier = Copier.new(provider_key: "snaptrade", legacy_item_id: item.id)
      connection = finish_copy(copier)

      assert_nil connection.credentials.fetch("oauth_token_expires_at")
      assert_nil connection.credentials.fetch("oauth_scope")
      assert_nil connection.credentials.fetch("oauth_token_type")
      assert_nil item_archive(copier).fetch("attributes").fetch("oauth_token_expires_at")
      assert connection.provider_sync_checkpoints.all? { |checkpoint| checkpoint.covered_through.nil? }
    ensure
      cleanup_item_copy(item) if item
    end
  end

  private
    def currency_item(provider_key, family:, currency:)
      if provider_key == "trading212"
        Trading212Item.create!(family: family, name: "Brokerage", currency: currency,
          api_key: "key", api_secret: "secret", environment: "demo")
      else
        TradeRepublicItem.create!(family: family, name: "Brokerage", currency: currency, session_blob: "retained-session")
      end
    end

    def finish_copy(copier)
      10.times do
        control = copier.run_quiesced
        if control.high_water_mark["phase"] == "verified"
          assert control.quiescing?
          assert_equal "quiesced", control.audit_results["copy_mode"]
          assert_equal true, control.audit_results["declared_writer_fence_held"]
          return control.provider_connection.reload
        end
      end
      flunk "Migration did not finish its bounded copy"
    end

    def item_archive(copier)
      copier.snapshot_for(copier.control.provider_migration_mappings.find_by!(role: "connection"))
    end

    def cleanup_item_copy(item)
      # Follow IdentityBootstrapTestHelper's retained-evidence ordering. These
      # tests create no provider accounts or financial accounts to remove.
      control = ProviderMigrationControl.find_by(legacy_type: item.class.name, legacy_id: item.id)
      connection = control&.provider_connection
      connection&.provider_sync_checkpoints&.delete_all
      ProviderMigrationAccountBinding.where(family_id: control.family_id,
        provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
      connection&.ingestion_batches&.delete_all
      control&.provider_migration_mappings&.delete_all
      control&.delete
      connection&.destroy!
      item.delete
    end
end
