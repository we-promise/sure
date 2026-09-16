require_relative "provider_ingestion_test_helper"

module AkahuNativeManagementTestHelper
  include ProviderIngestionTestHelper

  def with_akahu_connection
    with_provider_encryption do
      family = Family.create!(name: "Akahu native management")
      actor = family.users.create!(email: "akahu-management-#{SecureRandom.uuid}@example.com",
        password: "native-management-password", role: "admin")
      connection = create_provider_connection(family: family, provider_key: "akahu",
        credentials: { "app_token" => "original-app-token", "user_token" => "original-user-token" })
      yield connection, actor
    ensure
      cleanup_akahu_management_family(family) if family
    end
  end

  def with_copied_unlinked_akahu(rows: [], activate: true)
    with_akahu_connection do |empty_connection, actor|
      empty_connection.destroy!
      item = actor.family.akahu_items.create!(name: "Copied Akahu", app_token: "original-app-token",
        user_token: "original-user-token")
      source = item.akahu_accounts.create!(account_id: "native-setup-akahu", name: "Unlinked KiwiSaver",
        currency: "NZD", account_type: "KIWISAVER", current_balance: 100, raw_transactions_payload: rows)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "akahu", legacy_item_id: item.id, batch_size: 1)
      control = nil
      30.times do
        control = copier.run_quiesced.reload
        break if control.high_water_mark["phase"] == "verified"
      end
      assert_equal "verified", control.high_water_mark["phase"]
      preparation = nil
      150.times do
        preparation = Provider::AccountData::MigrationPreparation.new(provider_key: "akahu", legacy_item_id: item.id,
          family: actor.family, page_size: 1).run
        break if preparation.awaiting_acceptance?
      end
      assert preparation.awaiting_acceptance?
      connection = control.provider_connection.reload
      external = connection.external_accounts.sole
      if activate
        result = Provider::AccountData::MigrationCutover.new(provider_key: "akahu", legacy_item_id: item.id,
          family: actor.family, page_size: 1).call
        client = mock("native Akahu discovery")
        client.expects(:get_accounts_page).with(cursor: nil).returns(items: [ {
          _id: source.account_id, name: source.name, type: source.account_type,
          balance: { currency: "NZD", current: "100.00" }
        } ], next_cursor: nil)
        Provider::Akahu.stubs(:new).returns(client)
        SyncJob.perform_now(Sync.find(result.sync_id))
        assert Sync.find(result.sync_id).completed?
        clear_enqueued_jobs
      end
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
      yield connection.reload, actor, external.reload, source, mapping
    end
  end

  def akahu_archive_snapshot(connection)
    { batches: connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text")),
      bindings: ProviderMigrationAccountBinding.where(family_id: connection.family_id).order(:id).map(&:attributes),
      mappings: ProviderMigrationMapping.where(provider_connection_id: connection.id).or(
        ProviderMigrationMapping.where(external_account_id: connection.external_accounts.select(:id))).order(:id).map(&:attributes) }
  end

  def cleanup_akahu_management_family(family)
    clear_enqueued_jobs
    connections = family.provider_connections.to_a
    connections.each { |connection| connection.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil) }
    ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
    observations = SourceRecord.where(family_id: family.id)
    EntrySource.where(source_record_id: observations.select(:id)).delete_all
    HoldingSource.where(source_record_id: observations.select(:id)).delete_all
    observations.delete_all
    ProviderSyncCheckpoint.where(family_id: family.id).delete_all
    IngestionBatch.where(family_id: family.id).delete_all
    ProviderSyncGeneration.where(family_id: family.id).delete_all
    Account::SourcePolicy.where(family_id: family.id).delete_all
    AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
    ProviderMigrationMapping.where(family_id: family.id).delete_all
    ProviderMigrationControl.where(family_id: family.id).delete_all
    Sync.for_family(family).destroy_all
    connections.each { |connection| connection.reload.destroy! }
    family.akahu_items.each do |item|
      item.akahu_accounts.delete_all
      item.delete
    end
    family.accounts.destroy_all
    family.users.destroy_all
    family.destroy!
  end
end
