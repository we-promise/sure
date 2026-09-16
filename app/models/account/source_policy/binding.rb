# The source selected by one policy revision. Later link enrichment or removal
# cannot change this tuple; unknown old revisions are never filled from live data.
class Account::SourcePolicy::Binding
  FORMAT = "account-source-policy/v1".freeze
  FIELDS = %w[format capture_kind account_id family_id account_provider_id provider_key
    external_account_id provider_connection_id legacy_account_type legacy_account_id legacy_item_type legacy_item_id].freeze
  UUID = Ingestion::SourceOwners::UUID
  LINK_COLUMNS = Ingestion::SourceOwners::LINK_COLUMNS

  class Conflict < Provider::AccountData::InvalidResponse; end
  class Busy < Provider::AccountData::IncompletePage; end

  class << self
    def capture!(account:, account_provider:)
      unless account.is_a?(Account) && account_provider.is_a?(AccountProvider) && account_provider.persisted? &&
          account_provider.account_id == account.id
        raise Conflict, "Expected a live account and selected provider link"
      end
      ApplicationRecord.uncached do
        Account::SourcePolicy.transaction(requires_new: true) do
          identity = Account::IngestionIdentity.capture!(account: account)
          link = AccountProvider.where(id: account_provider.id, account_id: identity.id, family_id: identity.family_id)
            .lock("FOR UPDATE NOWAIT").first!
          before = owners(link)
          lock_owners!(before.proof)
          after = owners(link.reload)
          raise Conflict, "Source ownership changed during selection" unless before.proof == after.proof
          projection(link, after.proof)
        end
      end
    rescue ActiveRecord::LockWaitTimeout, Account::IngestionIdentity::Busy, Provider::AccountData::RetiredOwner::Busy
      raise Busy, "Selected source is being changed; retry selection", cause: nil
    rescue ActiveRecord::RecordNotFound, Account::IngestionIdentity::Conflict, Ingestion::SourceOwners::InvalidGraph,
        Provider::AccountData::RetiredOwner::Conflict
      raise Conflict, "Selected source ownership cannot be established", cause: nil
    end

    def validate!(binding, policy:)
      unless binding.is_a?(Hash) && binding.keys.all? { |key| key.is_a?(String) } && binding.keys.sort == FIELDS.sort && binding["format"] == FORMAT &&
          binding["capture_kind"] == "selection" && binding["provider_key"].is_a?(String) && binding["provider_key"].present? &&
          %w[account_id family_id account_provider_id].all? { |key| uuid?(binding[key]) && binding[key] == policy[key] }
        raise Conflict, "Source policy has no complete captured owner"
      end
      shared = [ binding["external_account_id"], binding["provider_connection_id"] ]
      legacy = binding.values_at("legacy_account_type", "legacy_account_id", "legacy_item_type", "legacy_item_id")
      unless shared.all?(&:nil?) || shared.all? { |id| uuid?(id) }
        raise Conflict, "Source policy has an incomplete shared owner"
      end
      unless legacy.all?(&:nil?)
        manifest = Provider::AccountData::MigrationManifest.all.find { |candidate| candidate.account_type == legacy[0] }
        unless manifest && manifest.provider_key == binding["provider_key"] && manifest.item_type == legacy[2] && uuid?(legacy[1]) && uuid?(legacy[3])
          raise Conflict, "Source policy has an invalid legacy owner"
        end
      end
      raise Conflict, "Source policy has no captured source" if shared.all?(&:nil?) && legacy.all?(&:nil?)
      Provider::AccountData::Registry.declared_adapter(binding["provider_key"])
      true
    rescue Provider::AccountData::UnsupportedCapability
      raise Conflict, "Source policy has an unregistered provider", cause: nil
    end

    # A copied legacy link can acquire its verified shared counterpart without
    # rewriting old policy history. SourceOwners proves the exact dual mapping.
    def verify_live!(policy:)
      validate!(policy.source_binding, policy: policy)
      link = policy.account_provider
      raise Conflict, "Selected source has no live provider link" unless link
      current = capture!(account: policy.account, account_provider: link)
      original = policy.source_binding
      same = %w[account_id family_id account_provider_id provider_key legacy_account_type legacy_account_id legacy_item_type legacy_item_id]
        .all? { |key| current[key] == original[key] }
      same &&= %w[external_account_id provider_connection_id].all? { |key| current[key] == original[key] } if original["external_account_id"]
      raise Conflict, "Selected source differs from its captured owner" unless same
      true
    end

    private
      def uuid?(value) = value.is_a?(String) && value.match?(UUID)

      def owners(link)
        Ingestion::SourceOwners.capture(family_id: link.family_id, links: [ link.attributes.slice(*LINK_COLUMNS) ],
          direct_sources: [], external_ids: [])
      end

      def lock_owners!(proof)
        manifests = Provider::AccountData::MigrationManifest.all
        legacy_models = manifests.flat_map { |manifest| [ manifest.item_type, manifest.account_type ] }.uniq.index_with(&:constantize)
        { "connections" => ProviderConnection, "external_accounts" => ExternalAccount,
          "controls" => ProviderMigrationControl, "mappings" => ProviderMigrationMapping }.each do |kind, model|
          proof.fetch(kind).sort_by { |row| row.fetch("id") }.each do |row|
            model.where(id: row.fetch("id")).select(:id).lock("FOR UPDATE NOWAIT").first!
          end
        end
        %w[legacy_items legacy_accounts].each do |kind|
          proof.fetch(kind).sort_by { |row| [ row.fetch("type"), row.fetch("id") ] }.each do |row|
            if row["retired_owner"]
              Provider::AccountData::RetiredOwner.lock_proof!(row.fetch("retired_owner"))
            else
              legacy_models.fetch(row.fetch("type")).where(id: row.fetch("id")).select(:id).lock("FOR UPDATE NOWAIT").first!
            end
          end
        end
      end

      def projection(link, proof)
        external = proof.fetch("external_accounts").find { |row| row["id"] == link.external_account_id }
        legacy = proof.fetch("legacy_accounts").find { |row| row["type"] == link.provider_type && row["id"] == link.provider_id }
        manifest = Provider::AccountData::MigrationManifest.all.find { |candidate| candidate.account_type == link.provider_type } if legacy
        Provider::AccountData::MigrationManifest.copy_value({
          "format" => FORMAT, "capture_kind" => "selection", "account_id" => link.account_id,
          "family_id" => link.family_id, "account_provider_id" => link.id,
          "provider_key" => external ? external.fetch("provider_key") : manifest.provider_key,
          "external_account_id" => external&.fetch("id"), "provider_connection_id" => external&.fetch("provider_connection_id"),
          "legacy_account_type" => legacy&.fetch("type"), "legacy_account_id" => legacy&.fetch("id"),
          "legacy_item_type" => manifest&.item_type, "legacy_item_id" => legacy&.fetch("item_id")
        })
      end
  end
end
