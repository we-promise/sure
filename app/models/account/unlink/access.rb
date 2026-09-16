# Unlink is an account-local operation. It preserves native connections and their
# retained evidence, including the compatibility rows of migrated providers.
class Account::Unlink::Access
  Fence = Provider::AccountData::LegacyWriterFence
  Owners = Ingestion::SourceOwners
  Disposition = Data.define(:native_link_ids, :preserved_legacy_sources)
  Snapshot = Data.define(:proof, :owners, :legacy_items, :disposition)

  def self.with_account(account, &block)
    new(account).with_account(&block)
  end

  def initialize(account)
    unless account.is_a?(Account) && account.persisted? && account.id.to_s.match?(Fence::UUID) && account.family_id.to_s.match?(Fence::UUID)
      raise Fence::InvalidSource, "Expected a persisted financial account"
    end
    @account_id, @family_id = account.id, account.family_id
    @manifests = Provider::AccountData::MigrationManifest.all
    @legacy_models = @manifests.flat_map { |manifest| [ manifest.item_type, manifest.account_type ] }.uniq.index_with(&:constantize)
  end

  def with_account
    ApplicationRecord.uncached do
      captured = snapshot
      Fence.with_items(captured.legacy_items, operation: :lifecycle) do
        Account.transaction(requires_new: true) do
          # Native publishers take the connection before financial accounts.
          # All later locks are nonblocking so an existing caller's lock order
          # cannot turn an unlink into a deadlock with another lifecycle command.
          lock_rows!(ProviderConnection, captured.owners.connection_ids)
          lock_rows!(ProviderMigrationControl, captured.owners.control_ids)
          current = Account::SyncAdmission.fetch!(account_id: @account_id, family_id: @family_id, lock: true)
          lock_sources!(captured.owners)
          checked = snapshot
          unless checked.proof == captured.proof
            raise Fence::OwnershipChanged, "Account provider links changed before unlink admission"
          end
          yield current, checked.disposition
        end
      end
    end
  rescue ActiveRecord::RecordNotFound, Account::SyncAdmission::Unavailable, Owners::InvalidGraph,
      Provider::AccountData::RetiredOwner::Conflict
    raise Fence::OwnershipChanged, "Account provider ownership is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout, Provider::AccountData::RetiredOwner::Busy
    raise Fence::Busy, "Account provider links are being changed; retry unlinking", cause: nil
  end

  private
    def snapshot
      financial = Account.where(id: @account_id, family_id: @family_id)
        .select(:id, :family_id, :status, *Owners::DIRECT_COLUMNS.values).first!
      links = AccountProvider.where(account_id: @account_id).order(:id)
        .limit(Owners::MAX_ROWS + 1).map { |link| link.attributes.slice(*Owners::LINK_COLUMNS) }
      direct = Owners::DIRECT_COLUMNS.filter_map do |type, column|
        id = financial.read_attribute(column)
        { "account_id" => @account_id, "provider_type" => type, "provider_id" => id } if id
      end
      owners = Owners.capture(family_id: @family_id, links: links, direct_sources: direct, external_ids: [])
      controls = owners.proof.fetch("controls")
      unless controls.all? { |row| (ProviderMigrationControl::LEGACY_STATES + ProviderMigrationControl::NATIVE_STATES).include?(row.fetch("state")) }
        raise Fence::OwnershipChanged, "Provider ownership is changing; retry unlinking"
      end
      native_items = controls.select { |row| ProviderMigrationControl::NATIVE_STATES.include?(row.fetch("state")) }
        .map { |row| row.values_at("legacy_type", "legacy_id") }
      native_connections = owners.connection_ids.reject do |id|
        controls.any? { |row| row["provider_connection_id"] == id && ProviderMigrationControl::LEGACY_STATES.include?(row["state"]) }
      end
      native_externals = owners.proof.fetch("external_accounts")
        .select { |row| native_connections.include?(row.fetch("provider_connection_id")) }.map { |row| row.fetch("id") }
      preserved = owners.legacy_accounts.filter_map do |type, id, item_id|
        manifest = @manifests.find { |candidate| candidate.account_type == type }
        [ type, id ] if native_items.include?([ manifest.item_type, item_id ])
      end
      links.each do |link|
        shared_native = native_externals.include?(link["external_account_id"])
        legacy_native = preserved.include?(link.values_at("provider_type", "provider_id"))
        # A legacy-owned copy cannot become a native-only source simply because
        # a link lost its legacy fields. Conversely, native ownership must have
        # its exact shared counterpart before removing compatibility links.
        if (link["provider_type"].nil? && !shared_native) || (legacy_native && !shared_native)
          raise Fence::OwnershipChanged, "Provider link has no usable current writer"
        end
      end
      direct.each do |source|
        next unless preserved.include?(source.values_at("provider_type", "provider_id"))
        unless owners.proof.fetch("mappings").any? { |row| row["role"] == "external_account" &&
            row["legacy_type"] == source["provider_type"] && row["legacy_id"] == source["provider_id"] && native_externals.include?(row["external_account_id"]) }
          raise Fence::OwnershipChanged, "Direct provider link has no shared counterpart"
        end
      end
      legacy_items = owners.legacy_items.reject { |tuple| native_items.include?(tuple) }.map do |type, id|
        @legacy_models.fetch(type).where(id: id, family_id: @family_id).first!
      end
      disposition = Disposition.new(
        native_link_ids: links.select { |link| native_externals.include?(link["external_account_id"]) }.map { |link| link.fetch("id") }.freeze,
        preserved_legacy_sources: Provider::AccountData::MigrationManifest.copy_value(preserved))
      Snapshot.new(proof: { "account" => financial.attributes, "owners" => owners.proof },
        owners: owners, legacy_items: legacy_items, disposition: disposition)
    end

    def lock_sources!(owners)
      %w[legacy_items legacy_accounts].each do |kind|
        rows = owners.proof.fetch(kind)
        rows.reject { |row| row["retired_owner"] }.group_by { |row| row.fetch("type") }.sort.each do |type, live|
          lock_rows!(@legacy_models.fetch(type), live.map { |row| row.fetch("id") })
        end
        rows.select { |row| row["retired_owner"] }.sort_by { |row| [ row.fetch("type"), row.fetch("id") ] }.each do |row|
          Provider::AccountData::RetiredOwner.lock_proof!(row.fetch("retired_owner"))
        end
      end
      lock_rows!(ExternalAccount, owners.external_ids)
      lock_rows!(ProviderMigrationMapping, owners.mapping_ids)
      lock_rows!(AccountProvider, owners.proof.fetch("links").map { |row| row.fetch("id") })
    end

    def lock_rows!(model, ids)
      locked = model.where(id: ids).select(:id).order(:id).lock("FOR UPDATE NOWAIT").map(&:id)
      raise Fence::OwnershipChanged, "Account provider ownership changed during unlink" unless locked == ids.sort
    end
end
