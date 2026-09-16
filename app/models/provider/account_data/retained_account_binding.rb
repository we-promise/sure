# Runtime use of an original account archive after its live link is removed.
# Detachment permits source-only interpretation, never reuse of its old financial
# policy or reconstruction of a financial owner from the retained UUID.
class Provider::AccountData::RetainedAccountBinding
  Copier = Provider::AccountData::MigrationCopier
  UUID = Provider::AccountData::LegacyWriterFence::UUID

  def self.classify!(retained:, external_account:)
    context = retained.context
    original = Copier.account_binding!(archive: retained.archive)
    financial, link = original.values_at("financial_context", "link")
    if financial
      unless uuid?(financial["id"]) && financial["family_id"] == external_account.family_id &&
          uuid?(financial["accountable_id"]) && financial["accountable_type"].is_a?(String) && financial["accountable_type"].present? &&
          uuid?(link["id"]) && link["account_id"] == financial["id"] && link["family_id"] == external_account.family_id &&
          link["provider_key"] == external_account.provider_key && link["external_account_id"] == external_account.id &&
          link["provider_type"] == context.fetch("legacy_type") && link["provider_id"] == context.fetch("legacy_id") &&
          link["lock_version"].is_a?(Integer) && link["lock_version"] >= 0
        raise Copier::Conflict, "Retained account binding has inconsistent original ownership"
      end
    end
    current_link, current_financial = external_account.account_provider, external_account.current_account
    if current_link || current_financial || !financial
      Copier.verify_account_binding!(archive: retained.archive, link: current_link, financial: current_financial)
      return current_link ? :linked : :unlinked
    end
    assert_detached!(external_account: external_account, control_id: context.fetch("control_id"),
      account_id: financial.fetch("id"), account_provider_id: link.fetch("id"),
      legacy_type: context.fetch("legacy_type"), legacy_id: context.fetch("legacy_id"))
    :detached
  end

  # The caller has already authenticated its original archive or signed receipt.
  # An absent current AP cannot conceal a moved/replaced legacy link or a source
  # that still has a direct financial owner.
  def self.assert_detached!(external_account:, control_id:, account_id:, account_provider_id:, legacy_type:, legacy_id:)
    family_id = external_account.family_id
    manifest = Provider::AccountData::MigrationManifest.for(external_account.provider_key)
    unless [ control_id, account_id, account_provider_id, legacy_id ].all? { |id| uuid?(id) } &&
        legacy_type == manifest.account_type &&
        ProviderMigrationControl.where(id: control_id, family_id: family_id, provider_key: external_account.provider_key,
          legacy_type: manifest.item_type, provider_connection_id: external_account.provider_connection_id,
          state: ProviderMigrationControl::NATIVE_STATES).exists? &&
        ProviderMigrationMapping.where(provider_migration_control_id: control_id, family_id: family_id,
          role: "external_account", legacy_type: legacy_type, legacy_id: legacy_id, external_account_id: external_account.id).exists? &&
        !AccountProvider.where(external_account_id: external_account.id).exists? &&
        !AccountProvider.where(id: account_provider_id).exists? &&
        !AccountProvider.where(provider_type: legacy_type, provider_id: legacy_id).exists?
      raise Copier::Conflict, "Retained account has no verified detached source disposition"
    end
    direct_column = { "PlaidAccount" => :plaid_account_id, "SimplefinAccount" => :simplefin_account_id }[legacy_type]
    if (direct_column && Account.where(direct_column => legacy_id).exists?) ||
        Account.where(id: account_id).where.not(family_id: family_id).exists? ||
        Account::IngestionIdentity.where(id: account_id).where.not(family_id: family_id).exists?
      raise Copier::Conflict, "Detached retained account has conflicting financial ownership"
    end
    true
  end

  def self.uuid?(value) = value.is_a?(String) && value.match?(UUID)
  private_class_method :uuid?
end
