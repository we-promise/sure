require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Questrade::RetainedCredentialsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Retained = Provider::AccountData::Questrade::RetainedCredentials
  Copier = Provider::AccountData::MigrationCopier
  Fence = Provider::AccountData::LegacyWriterFence
  Registry = Provider::AccountData::Registry
  OLD_API = "https://api01.iq.questrade.com/".freeze
  NEW_API = "https://api02.iq.questrade.com/".freeze

  setup do
    DebugLogEntry.stubs(:capture)
    QuestradeItem.any_instance.stubs(:broadcast_replace_to)
    Registry.stubs(:fetch).with("questrade").returns(Provider::AccountData::Questrade)
    clear_enqueued_jobs
  end

  teardown { clear_enqueued_jobs }

  test "actual quiesced token reaches native exchange and replacement commits before authenticated data" do
    with_item do |item, copier|
      connection = finish_copy(copier)
      mapping = copier.control.provider_migration_mappings.find_by!(role: "connection")
      original = copier.snapshot_for(mapping)
      assert_equal "original-token", connection.credentials.fetch("refresh_token")
      assert_equal OLD_API, connection.settings.fetch("api_server")
      assert_equal OLD_API, original.fetch("attributes").fetch("api_server")
      assert_provider_column_encrypted(connection, :credentials, "original-token")
      before = retained_storage(connection)
      native_fixture!(copier.control, connection)

      exchange = token_response do
        current = connection.reload
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal "refreshing", current.credential_state.fetch("status")
        assert_equal "original-token", current.credentials.fetch("refresh_token")
        assert_raises(Fence::OwnershipChanged) { item.questrade_provider.list_accounts }
      end
      data = stub_request(:get, "#{NEW_API}v1/accounts").with(headers: { Authorization: "Bearer new-access" }).to_return do
        current = connection.reload
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal "new-refresh", current.credentials.fetch("refresh_token")
        assert_equal NEW_API, current.credentials.fetch("api_server")
        assert_equal "live", current.credentials.fetch("environment")
        assert current.credentials.fetch("expires_at").present?
        assert_empty current.credential_state
        assert_equal 1, current.credential_revision
        { status: 200, body: '{"accounts":[]}' }
      end

      adapter = build(connection)
      page, capture = adapter.request_grant.capture_request { adapter.list_accounts }
      assert page.complete?
      assert_empty page.records
      assert_equal [ "refresh" ], capture.fetch("rotations").map { |rotation| rotation.fetch("kind") }
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
      assert capture.dig("after", "runtime_inputs", "frozen_context", "questrade_retained_credentials").present?
      refute_includes capture.inspect, "original-token"
      refute_includes capture.inspect, "new-refresh"
      assert_equal "original-token", item.reload.refresh_token
      assert_equal OLD_API, item.api_server
      assert_equal original, copier.snapshot_for(mapping.reload)
      assert_equal before, retained_storage(connection)
      assert_equal OLD_API, connection.reload.settings.fetch("api_server")
      assert_requested exchange, times: 1
      assert_requested data, times: 1
      assert_not_requested :get, "#{OLD_API}v1/accounts"

      # A fresh factory uses the committed access token, not the copied legacy
      # refresh token or historical API-server setting.
      other = build(connection.reload)
      other.request_grant.capture_request { other.list_accounts }
      assert_requested exchange, times: 1
      assert_requested data, times: 2
      refute Provider::AccountData::Questrade.native_ready?
    end
  end

  test "disabled and still-quiescing copies cannot lend native credentials" do
    with_item do |_item, copier|
      connection = finish_copy(copier)
      HTTParty.expects(:post).never
      HTTParty.expects(:get).never
      adapter = build(connection)
      assert_raises(Provider::AccountData::StaleWriter) { adapter.request_grant.capture_request { adapter.list_accounts } }
      connection.update!(status: "good")
      adapter = build(connection)
      assert_raises(Provider::AccountData::StaleWriter) { adapter.request_grant.capture_request { adapter.list_accounts } }
      assert_equal "original-token", connection.reload.credentials.fetch("refresh_token")
      assert_empty connection.credential_state
    end
  end

  test "native uncertain exchange retains committed intent and cannot reuse native or legacy token" do
    with_item do |item, copier|
      connection = finish_copy(copier)
      native_fixture!(copier.control, connection)
      exchange = stub_request(:post, Provider::Questrade::LOGIN_URL).to_raise(Net::ReadTimeout.new("private-token"))
      HTTParty.expects(:get).never
      adapter = build(connection)
      error = assert_raises(Provider::Questrade::AuthenticationError) do
        adapter.request_grant.capture_request { adapter.list_accounts }
      end
      assert_equal :refresh_uncertain, error.error_type
      assert connection.reload.requires_update?
      assert_equal "uncertain", connection.credential_state.fetch("status")
      assert_equal "original-token", connection.credentials.fetch("refresh_token")
      assert_equal 0, connection.credential_revision
      assert_raises(Fence::OwnershipChanged) { item.questrade_provider.list_accounts }
      other = build(connection)
      assert_raises(Provider::Questrade::AuthenticationError) do
        other.request_grant.capture_request { other.list_accounts }
      end
      assert_requested exchange, times: 1
      refute_includes error.message, "private-token"
      assert_nil error.cause
    end
  end

  test "failed rotated credential commit cannot expose the in-memory bearer to financial reads" do
    with_item do |_item, copier|
      connection = finish_copy(copier)
      native_fixture!(copier.control, connection)
      exchange = token_response
      HTTParty.expects(:get).never
      callback = ->(current) do
        raise IOError, "private database error" if current.id == connection.id && current.credentials["refresh_token"] == "new-refresh"
      end
      ProviderConnection.set_callback(:save, :after, callback)
      begin
        adapter = build(connection)
        assert_raises(Provider::Questrade::AuthenticationError) do
          adapter.request_grant.capture_request { adapter.list_accounts }
        end
      ensure
        ProviderConnection.skip_callback(:save, :after, callback)
      end
      assert_equal "original-token", connection.reload.credentials.fetch("refresh_token")
      assert_equal 0, connection.credential_revision
      assert_includes %w[refreshing uncertain], connection.credential_state.fetch("status")
      other = build(connection)
      assert_raises(Provider::Questrade::AuthenticationError) { other.request_grant.capture_request { other.list_accounts } }
      assert_requested exchange, times: 1
    end
  end

  test "an uncertain legacy exchange blocks quiesced copy and preparation until explicit legacy replacement" do
    with_item do |item, copier|
      exchange = stub_request(:post, Provider::Questrade::LOGIN_URL).to_raise(Net::ReadTimeout.new("private-token"))
      assert_raises(Provider::Questrade::AuthenticationError) { item.questrade_provider.list_accounts }
      assert item.reload.requires_update?
      assert_raises(Provider::Questrade::AuthenticationError) { item.questrade_provider.list_accounts }
      assert_raises(Copier::Conflict) { copier.run_quiesced }
      preparation = Provider::AccountData::MigrationPreparation.new(provider_key: "questrade", legacy_item_id: item.id, family: item.family, page_size: 1)
      assert_raises(Copier::Conflict) { preparation.run }
      assert_nil ProviderMigrationControl.find_by(legacy_type: "QuestradeItem", legacy_id: item.id)
      assert_requested exchange, times: 1

      QuestradeItem::CredentialSession.with(item, allow_unusable: true) do |session|
        session.replace!(refresh_token: "reauthorized-token")
      end
      connection = finish_copy(copier)
      assert_equal "reauthorized-token", connection.credentials.fetch("refresh_token")
      assert_nil connection.settings.fetch("api_server")
      assert_equal "good", Retained.build(connection: connection, observed_at: Time.current).fetch("status")
    end
  end

  test "changed legacy token after verified copy invalidates original verification and preparation" do
    with_item do |item, copier|
      connection = finish_copy(copier)
      before = retained_storage(connection)
      # Simulate an old deployment writing outside the declared fence. Neither
      # retained verification nor preparation may refresh the original archive.
      item.update_columns(refresh_token: "unexpected-token")
      assert_raises(Copier::SourceChanged) { copier.verify_retained_quiesced_page(family: item.family, limit: 1) }
      preparation = Provider::AccountData::MigrationPreparation.new(provider_key: "questrade", legacy_item_id: item.id, family: item.family, page_size: 1)
      assert_raises(Copier::SourceChanged) { preparation.run }
      assert_equal before, retained_storage(connection)
      assert_equal "original-token", connection.reload.credentials.fetch("refresh_token")
      assert connection.disabled?
      assert_empty connection.syncs
    end
  end

  test "old copied uncertain status never becomes authority from a changed native token or revision" do
    with_item do |item, copier|
      connection = finish_copy(copier)
      retain_old_uncertain_archive(item, copier, connection)
      native_fixture!(copier.control, connection)
      HTTParty.expects(:post).never
      HTTParty.expects(:get).never
      assert_raises(Provider::AccountData::StaleWriter) { build(connection) }
      connection.update!(credentials: { "refresh_token" => "unproved-replacement" })
      assert_equal 1, connection.credential_revision
      assert_raises(Provider::AccountData::StaleWriter) { build(connection) }
    end
  end

  test "changed retained descriptor invalidates a previously built request before HTTP" do
    with_item do |_item, copier|
      connection = finish_copy(copier)
      native_fixture!(copier.control, connection)
      adapter = build(connection)
      mapping = copier.control.provider_migration_mappings.find_by!(role: "connection")
      mapping.update!(source_version: "changed-source-version")
      HTTParty.expects(:post).never
      assert_raises(Provider::AccountData::StaleWriter) { adapter.request_grant.capture_request { adapter.list_accounts } }
    end
  end

  test "a genuinely new native connection has no fictitious legacy credential proof" do
    with_provider_encryption do
      family = Family.create!(name: "Fresh Questrade native credentials")
      connection = family.provider_connections.create!(provider_key: "questrade", name: "Native", credentials: { "refresh_token" => "original-token" })
      assert_nil Retained.live_input(connection: connection)
      assert_nil Retained.build(connection: connection, observed_at: Time.current)
      exchange = token_response
      stub_request(:get, "#{NEW_API}v1/accounts").to_return(status: 200, body: '{"accounts":[]}')
      adapter = build(connection)
      page, = adapter.request_grant.capture_request { adapter.list_accounts }
      assert page.complete?
      assert_requested exchange, times: 1
    ensure
      connection&.destroy!
      family&.destroy!
    end
  end

  private
    def build(connection)
      Registry.build(connection.reload, observed_at: Time.current)
    end

    def token_response(&before_response)
      stub_request(:post, Provider::Questrade::LOGIN_URL)
        .with(body: { grant_type: "refresh_token", refresh_token: "original-token" })
        .to_return do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          before_response&.call
          { status: 200, body: { access_token: "new-access", refresh_token: "new-refresh", api_server: NEW_API,
            token_type: "Bearer", expires_in: 1800 }.to_json }
        end
    end

    def finish_copy(copier)
      12.times do
        control = copier.run_quiesced
        next unless control.high_water_mark["phase"] == "verified"
        assert control.quiescing?
        assert_equal "quiesced", control.audit_results.fetch("copy_mode")
        return control.provider_connection.reload
      end
      flunk "Quiesced copy did not finish"
    end

    def native_fixture!(control, connection)
      # Test-only ownership fixture: Questrade cutover remains unavailable. The
      # real archived copy, RequestGrant and credential session are not mocked.
      ApplicationRecord.transaction do
        control.update!(state: "active", writer_epoch: 1)
        connection.update!(status: "good", writer_epoch: 1)
      end
    end

    def retain_old_uncertain_archive(item, copier, connection)
      # Reproduce a pre-admission-gate archive through the actual typed/HMAC
      # serializer. No encryption, archive reader or native gate is bypassed.
      item.update_columns(status: "requires_update")
      projection = copier.manifest.extract_item(item.reload)
      mapping = copier.control.provider_migration_mappings.find_by!(role: "connection")
      Fence.with_exclusive(item) do
        copier.control.with_lock do
          copier.send(:save_mapping!, mapping, connection, projection)
          copier.send(:capture_snapshot!, mapping, projection)
          mapping.update!(verified_at: Time.current)
        end
      end
      assert_equal "requires_update", copier.snapshot_for(mapping).fetch("attributes").fetch("status")
    end

    def retained_storage(connection)
      database = ApplicationRecord.connection
      { batches: database.select_all(connection.ingestion_batches.order(:id).select(:id, :payload).to_sql).to_a,
        checkpoints: connection.provider_sync_checkpoints.order(:id).map(&:attributes) }
    end

    def with_item
      with_provider_encryption do
        family = Family.create!(name: "Questrade retained credential handover")
        item = family.questrade_items.create!(name: "Brokerage", refresh_token: "original-token", api_server: OLD_API)
        copier = Copier.new(provider_key: "questrade", legacy_item_id: item.id, batch_size: 1)
        yield item, copier
      ensure
        control = item && ProviderMigrationControl.find_by(legacy_type: "QuestradeItem", legacy_id: item.id)
        connection = control&.provider_connection
        connection&.provider_sync_checkpoints&.delete_all
        connection&.ingestion_batches&.delete_all
        control&.provider_migration_mappings&.delete_all
        control&.delete
        connection&.destroy!
        item&.delete
        family&.destroy!
      end
    end
end
