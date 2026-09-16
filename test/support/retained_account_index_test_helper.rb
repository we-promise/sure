require_relative "provider_ingestion_test_helper"

module RetainedAccountIndexTestHelper
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  Context = Data.define(:family, :item, :source, :account, :link, :copier, :control, :mapping, :external)

  def with_retained_account_copy(linked: true)
    with_provider_encryption do
      family = Family.create!(name: "Retained account ownership")
      item = family.up_items.create!(name: "Retained Up", access_token: "private-retained-token")
      account = family.accounts.create!(name: "Original financial account", currency: "USD",
        balance: BigDecimal("123.4567"), accountable: Depository.new, status: "active")
      source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Provider account", currency: "USD",
        current_balance: BigDecimal("123.4567"), raw_payload: { "private" => "銀行" * 500 })
      link = AccountProvider.create!(account: account, provider: source) if linked
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "up", legacy_item_id: item.id,
        batch_size: 1, chunk_bytes: 1024)
      finish_retained_shadow_copy(copier)
      control = copier.control.reload
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: source.id)
      yield Context.new(family: family, item: item, source: source, account: account, link: link&.reload,
        copier: copier, control: control, mapping: mapping, external: mapping.external_account)
    ensure
      if family&.persisted?
        ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
        controls = ProviderMigrationControl.where(family_id: family.id)
        connections = ProviderConnection.where(family_id: family.id)
        ProviderSyncCheckpoint.where(provider_connection_id: connections.select(:id)).delete_all
        IngestionBatch.where(family_id: family.id).delete_all
        Account::SourcePolicy.where(account_id: family.accounts.select(:id)).delete_all
        AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
        ProviderMigrationMapping.where(provider_migration_control_id: controls.select(:id)).delete_all
        controls.delete_all
        connections.each(&:destroy!)
        UpAccount.where(up_item_id: item.id).delete_all if item
        item&.delete
        family.accounts.reload.each(&:destroy!)
        family.destroy!
        clear_enqueued_jobs
      end
    end
  end

  def finish_retained_shadow_copy(copier)
    # Always make the first call: a prior shadow starts a new comparison pass.
    20.times do
      return copier.control.reload if copier.run.shadow?
    end
    flunk "Retained ownership fixture did not finish its bounded shadow copy"
  end

  def retained_chunks(context, checksum: context.mapping.reload.source_checksum)
    prefix = "migration:#{context.control.id}:#{context.mapping.legacy_type}:#{context.mapping.legacy_id}:#{checksum}:"
    context.control.provider_connection.ingestion_batches.where(stream: "legacy_snapshot",
      external_account_id: context.external.id).where("idempotency_key LIKE ?", "#{prefix}%").order(:sequence)
  end

  def retained_receipt(context, checksum: context.mapping.reload.source_checksum)
    ProviderMigrationAccountBinding.find_by!(provider_migration_mapping_id: context.mapping.id, source_checksum: checksum)
  end
end
