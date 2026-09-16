# Explicitly scheduled by an operator. This only copies/verifies disabled shadow
# storage; it cannot activate a provider or change the financial ledger.
class ProviderDataMigrationJob < ApplicationJob
  retry_on Provider::AccountData::MigrationCopier::Busy, wait: 30.seconds, attempts: 20
  retry_on Provider::AccountData::MigrationCopier::SourceChanged, wait: 30.seconds, attempts: 20

  def perform(provider_key:, legacy_item_id:, family_id:)
    manifest = Provider::AccountData::MigrationManifest.for(provider_key)
    source = manifest.item_type.constantize.find(legacy_item_id)
    raise ArgumentError, "Migration source family changed" unless source.family_id == family_id

    control = Provider::AccountData::MigrationCopier.new(provider_key: provider_key, legacy_item_id: legacy_item_id).run
    if control.copying?
      self.class.perform_later(provider_key: provider_key, legacy_item_id: legacy_item_id, family_id: family_id)
    end
  end
end
