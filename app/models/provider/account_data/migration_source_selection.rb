# Select defaults before identity publication pins their revisions. This narrow
# contract is shared by cash-account migrations with reviewed cutover histories.
class Provider::AccountData::MigrationSourceSelection
  class Conflict < Provider::AccountData::StaleWriter; end
  PROVIDER_KEYS = %w[up mercury brex akahu enable_banking].freeze
  RESOURCES = %w[transactions balances].freeze

  def self.supports?(provider_key)
    PROVIDER_KEYS.include?(provider_key)
  end

  def self.ensure!(mapping:, family:)
    control = mapping.provider_migration_control
    unless supports?(control.provider_key) && control.family_id == family.id && mapping.family_id == family.id &&
        mapping.role == "external_account"
      raise Conflict, "Source selection requires its original reviewed account mapping"
    end
    manifest = Provider::AccountData::MigrationManifest.for(control.provider_key)
    unless mapping.legacy_type == manifest.account_type && control.legacy_type == manifest.item_type
      raise Conflict, "Source selection mapping belongs to another provider"
    end
    item = manifest.item_type.constantize.find_by!(id: control.legacy_id, family_id: family.id)
    Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)

    ApplicationRecord.transaction(requires_new: true) do
      control.lock!("FOR UPDATE NOWAIT")
      connection = ProviderConnection.where(id: control.provider_connection_id, family_id: family.id, provider_key: manifest.provider_key)
        .lock("FOR UPDATE NOWAIT").first!
      unless control.quiescing? && control.writer_epoch.zero? && connection.disabled? && connection.writer_epoch.zero? &&
          control.legacy_type == manifest.item_type && control.legacy_id == item.id && control.family_id == family.id &&
          control.provider_key == manifest.provider_key && !item.scheduled_for_deletion? && !connection.scheduled_for_deletion?
        raise Conflict, "Source defaults require the original disabled quiesced copy"
      end
      link = AccountProvider.find_by!(external_account_id: mapping.external_account_id, family_id: family.id)
      account = Account.where(id: link.account_id, family_id: family.id).lock("FOR UPDATE NOWAIT").first!
      link.lock!("FOR UPDATE NOWAIT")
      unless link.account_id == account.id && link.external_account_id == mapping.external_account_id &&
          link.provider_type == manifest.account_type && link.provider_id == mapping.legacy_id && link.provider_key == manifest.provider_key
        raise Conflict, "Source selection lost its original financial account"
      end
      policies = Account::SourcePolicy.active.where(account_id: account.id, resource: RESOURCES)
        .order(:resource).lock("FOR UPDATE NOWAIT").to_a
      policies.each { |policy| Account::SourcePolicy::Binding.verify_live!(policy: policy) }
      missing = RESOURCES - policies.map(&:resource)
      if missing.any?
        unless account.plaid_account_id.nil? && account.simplefin_account_id.nil? &&
            AccountProvider.where(account_id: account.id).pluck(:id) == [ link.id ]
          raise Conflict, "Choose account sources explicitly before preparing an account with multiple links"
        end
        Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: missing)
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Source ownership is missing or changed", cause: nil
  end
end
