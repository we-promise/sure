# Admission for unlinking the current provider links of one financial account.
# Account destruction also touches transfer counterparties and retained evidence;
# this inventory is deliberately not its destruction boundary.
class Account::Unlink::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  Manifest = Provider::AccountData::MigrationManifest
  LINK_COLUMNS = %w[id account_id provider_type provider_id external_account_id family_id provider_key lock_version].freeze
  EXTERNAL_COLUMNS = %w[id provider_connection_id family_id provider_key].freeze
  CONTROL_COLUMNS = %w[id family_id provider_key legacy_type legacy_id provider_connection_id state writer_epoch].freeze
  MAPPING_COLUMNS = %w[id provider_migration_control_id family_id role legacy_type legacy_id external_account_id].freeze
  DIRECT_SOURCES = { "plaid_account_id" => "PlaidAccount", "simplefin_account_id" => "SimplefinAccount" }.freeze
  Snapshot = Data.define(:proof, :items, :sources, :external_ids, :link_ids)

  def self.with_account(account, &block)
    new(account).with_account(&block)
  end

  def initialize(account)
    unless account.is_a?(Account) && account.persisted? && account.id.to_s.match?(Fence::UUID) && account.family_id.to_s.match?(Fence::UUID)
      raise Fence::InvalidSource, "Expected a persisted financial account"
    end
    @account_id, @family_id = account.id, account.family_id
    @manifests = Manifest.all.index_by(&:account_type)
  end

  def with_account
    ApplicationRecord.uncached do
      captured = snapshot
      Fence.with_items(captured.items, operation: :lifecycle) do
        # Unlink may be called from an already admitted outer transaction. Its
        # caller can handle failure and continue, so partial cleanup needs its
        # own rollback boundary.
        Account.transaction(requires_new: true) do
          current = account_scope.lock("FOR UPDATE NOWAIT").first!
          lock_sources!(captured)
          checked = snapshot
          unless checked.proof == captured.proof
            raise Fence::OwnershipChanged, "Account provider links changed before unlink admission"
          end
          yield current
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Account provider ownership is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Account provider links are being changed; retry unlinking", cause: nil
  end

  private
    def account_scope
      Account.where(id: @account_id, family_id: @family_id)
    end

    def snapshot
      financial = account_scope.select(:id, :family_id, *DIRECT_SOURCES.keys).first!
      links = AccountProvider.where(account_id: @account_id).order(:id).select(*LINK_COLUMNS).to_a
      external_ids = links.filter_map(&:external_account_id).uniq.sort
      externals = ExternalAccount.where(id: external_ids).select(*EXTERNAL_COLUMNS).index_by(&:id)
      unless externals.size == external_ids.size
        raise Fence::OwnershipChanged, "A shared provider link lost its external account"
      end
      sources, items, controls, mappings = {}, {}, {}, {}
      links.each do |link|
        unless link.provider_type.present? && link.provider_id.present?
          raise Fence::OwnershipChanged, "Shared provider unlinking requires its native lifecycle command"
        end
        manifest = manifest_for(link.provider_type)
        unless (link.family_id.nil? || link.family_id == @family_id) &&
            (link.provider_key.nil? || link.provider_key == manifest.provider_key)
          raise Fence::OwnershipChanged, "Account provider link belongs to another owner"
        end
        source, item = resolve_source(manifest, link.provider_id)
        sources[[ manifest.account_type, source.id ]] = [ manifest.account_type, source.id, item.id ]
        items[[ manifest.item_type, item.id ]] = item
        check_direct_owner!(manifest, source.id)
        if link.external_account_id
          external = externals.fetch(link.external_account_id)
          control, mapping = verify_dual_link!(manifest, source, item, link, external)
          controls[control.id] = control.attributes.slice(*CONTROL_COLUMNS)
          mappings[mapping.id] = mapping.attributes.slice(*MAPPING_COLUMNS)
        end
      end
      DIRECT_SOURCES.each do |column, type|
        id = financial.read_attribute(column)
        next unless id
        manifest = manifest_for(type)
        source, item = resolve_source(manifest, id)
        check_direct_owner!(manifest, id)
        if AccountProvider.where(provider_type: type, provider_id: id).where.not(account_id: @account_id).exists?
          raise Fence::OwnershipChanged, "Direct provider account is linked to another financial account"
        end
        own_link = links.find { |link| link.provider_type == type }
        if own_link && own_link.provider_id != id
          raise Fence::OwnershipChanged, "Direct and shared provider account links disagree"
        end
        sources[[ type, id ]] = [ type, id, item.id ]
        items[[ manifest.item_type, item.id ]] = item
      end
      proof = {
        "account" => financial.attributes, "links" => links.map(&:attributes),
        "sources" => sources.sort.map(&:last), "external_accounts" => externals.sort.map { |_, row| row.attributes },
        "controls" => controls.sort.map(&:last), "mappings" => mappings.sort.map(&:last)
      }
      Snapshot.new(proof: Manifest.copy_value(proof), items: items.sort.map(&:last).freeze,
        sources: Manifest.copy_value(sources.sort.map(&:last)), external_ids: external_ids.freeze, link_ids: links.map(&:id).freeze)
    end

    def manifest_for(type)
      @manifests.fetch(type) { raise Fence::InvalidSource, "Unregistered provider account link" }
    end

    def resolve_source(manifest, id)
      unless id.to_s.match?(Fence::UUID)
        raise Fence::InvalidSource, "Invalid provider account identity"
      end
      source = manifest.account_type.constantize.select(:id, manifest.account_foreign_key).find(id)
      item_id = source.read_attribute(manifest.account_foreign_key)
      item = manifest.item_type.constantize.where(id: item_id, family_id: @family_id).select(:id, :family_id).first!
      [ source, item ]
    end

    def check_direct_owner!(manifest, source_id)
      column = DIRECT_SOURCES.key(manifest.account_type)
      return unless column
      if Account.where(column => source_id).where.not(id: @account_id).exists?
        raise Fence::OwnershipChanged, "Provider account has a different direct financial owner"
      end
    end

    def verify_dual_link!(manifest, source, item, link, external)
      unless external.family_id == @family_id && external.provider_key == manifest.provider_key &&
          link.family_id == @family_id && link.provider_key == manifest.provider_key
        raise Fence::OwnershipChanged, "Shared provider link has inconsistent ownership"
      end
      connection = ProviderConnection.where(id: external.provider_connection_id, family_id: @family_id, provider_key: manifest.provider_key)
        .select(:id, :family_id, :provider_key).first!
      control = ProviderMigrationControl.where(provider_connection_id: connection.id).select(*CONTROL_COLUMNS).first!
      unless control.family_id == @family_id && control.provider_key == manifest.provider_key &&
          control.legacy_type == manifest.item_type && control.legacy_id == item.id && control.legacy_owned?
        raise Fence::OwnershipChanged, "Legacy unlinking no longer owns this provider connection"
      end
      mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: @family_id,
        role: "external_account", legacy_type: manifest.account_type, legacy_id: source.id, external_account_id: external.id)
        .select(*MAPPING_COLUMNS).first!
      [ control, mapping ]
    end

    def lock_sources!(captured)
      captured.items.group_by { |item| item.class.base_class }.sort_by { |klass, _| klass.name }.each do |klass, items|
        klass.where(id: items.map(&:id), family_id: @family_id).select(:id, :family_id)
          .order(:id).lock("FOR UPDATE NOWAIT").load
      end
      captured.sources.group_by(&:first).sort.each do |type, rows|
        manifest = manifest_for(type)
        manifest.account_type.constantize.where(id: rows.map { |row| row.fetch(1) })
          .select(:id, manifest.account_foreign_key).order(:id).lock("FOR UPDATE NOWAIT").load
      end
      ExternalAccount.where(id: captured.external_ids).select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
      AccountProvider.where(id: captured.link_ids, account_id: @account_id).select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
    end
end
