# The source-scoped financial portion of a native disconnect. The caller owns
# credential-session admission and atomically disables the connection/records its
# signed decision inside this block. This class never deletes financial evidence.
class ProviderConnection::Disconnect::Links
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end
  Fence = Provider::AccountData::LegacyWriterFence
  Owners = Ingestion::SourceOwners
  MAX_ACCOUNTS = 100
  MAX_ROWS = 10_000
  MAX_BINDING_BYTES = 4 * 1024 * 1024
  ACCOUNT_COLUMNS = %w[id family_id owner_id name status currency accountable_type accountable_id plaid_account_id simplefin_account_id].freeze
  POLICY_COLUMNS = %w[id account_id family_id account_provider_id resource revision active source_binding].freeze
  Context = Data.define(:connection, :accounts, :binding, :operation, :admission) do
    def detach!
      operation.detach!(admission: admission)
    end

    def inspect = "#<#{self.class.name}>"
  end

  def initialize(connection_id:, family_id:, actor_id:)
    unless [ connection_id, family_id, actor_id ].all? { |id| id.is_a?(String) && Fence::UUID.match?(id) }
      raise ArgumentError, "Disconnect requires exact connection, family and actor identities"
    end
    @connection_id, @family_id, @actor_id = connection_id.dup.freeze, family_id.dup.freeze, actor_id.dup.freeze
    @manifests = Provider::AccountData::MigrationManifest.all
    @legacy_models = @manifests.flat_map { |manifest| [ manifest.item_type, manifest.account_type ] }.uniq.index_with(&:constantize)
  end

  def with_locked
    unless ApplicationRecord.connection.open_transactions.zero?
      raise ArgumentError, "Disconnect must acquire all legacy permits before a database transaction"
    end
    ApplicationRecord.uncached do
      captured = snapshot
      Fence.with_items(legacy_items(captured.fetch(:owners)), operation: :lifecycle) do
        ApplicationRecord.transaction(requires_new: true) do
          owners = captured.fetch(:owners)
          lock_rows!(ProviderConnection, owners.connection_ids)
          lock_rows!(ProviderMigrationControl, owners.control_ids)
          @connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id)
          @accounts = captured.fetch(:accounts).map do |row|
            Account::SyncAdmission.fetch!(account_id: row.fetch("id"), family_id: @family_id, lock: true)
          end
          lock_sources!(owners)
          lock_permissions!
          lock_rows!(Account::SourcePolicy, captured.fetch(:policies).map { |row| row.fetch("id") })
          lock_rows!(Holding, captured.fetch(:holdings).map { |row| row.fetch("id") })
          lock_rows!(Account::SyncSource, captured.fetch(:selections).map { |row| row.fetch("id") })
          checked = snapshot
          refuse! unless checked.fetch(:binding) == captured.fetch(:binding)
          assert_idle!(owners)
          authorize!
          @captured, @detached, @admission = checked, false, Object.new
          yield Context.new(connection: @connection, accounts: @accounts.freeze,
            binding: checked.fetch(:binding), operation: self, admission: @admission).freeze
        ensure
          @admission = nil
        end
      end
    end
  rescue ActiveRecord::LockWaitTimeout, Provider::AccountData::RetiredOwner::Busy, Fence::Busy
    raise Busy, "Account sources are busy; retry disconnect after outstanding work finishes", cause: nil
  rescue ActiveRecord::RecordNotFound, Account::SyncAdmission::Unavailable, Owners::InvalidGraph,
      Provider::AccountData::RetiredOwner::Conflict, Account::SourcePolicy::Binding::Conflict, Fence::OwnershipChanged
    refuse!
  end

  def detach!(admission: nil)
    unless admission && admission.equal?(@admission) && ApplicationRecord.connection.transaction_open? && !@detached
      raise Conflict, "Disconnect links require their current locked admission"
    end
    selected_ids = @captured.fetch(:selected_link_ids)
    policies = Account::SourcePolicy.where(id: @captured.fetch(:policies).select { |row| selected_ids.include?(row.fetch("account_provider_id")) }.map { |row| row.fetch("id") }).order(:id).to_a
    policies.each do |policy|
      refuse! if policy.source_binding.blank?
      Account::SourcePolicy::Binding.verify_live!(policy: policy)
    end
    Account::SourcePolicy.where(id: policies.map(&:id), active: true).update_all(active: false, updated_at: Time.current)
    @captured.fetch(:selections).select { |row| row.fetch("provider_connection_id") == @connection_id }.each do |row|
      Account::SyncSource.find(row.fetch("id")).destroy!
    end
    Holding.where(id: @captured.fetch(:holdings).map { |row| row.fetch("id") }).update_all(account_provider_id: nil)
    # Native tracking rows and their immutable legacy tuples remain in archives;
    # provider-specific AccountProvider destroy callbacks must not run here.
    unless AccountProvider.where(id: selected_ids).delete_all == selected_ids.size
      refuse!
    end
    @accounts.each do |account|
      cleared = @captured.fetch(:direct).select { |row| row.fetch("account_id") == account.id }
        .to_h { |row| [ Owners::DIRECT_COLUMNS.fetch(row.fetch("provider_type")), nil ] }
      next if cleared.empty?
      # Avoid Account's default-owner assignment and preserve unrelated fields.
      refuse! unless account.update_columns(cleared.merge("updated_at" => Time.current))
    end
    @detached = true
    true
  end

  # Receipt replay already owns Management's connection/control locks. It must
  # not acquire a legacy permit after those locks or decode every retained cache
  # merely to confirm the absence of current financial routing references.
  def assert_detached!
    raise ArgumentError, "Disconnect replay requires its management transaction" unless ApplicationRecord.connection.transaction_open?
    connection = ProviderConnection.where(id: @connection_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id).lock("FOR UPDATE NOWAIT").first
    refuse! if control && (control.family_id != @family_id || control.provider_key != connection.provider_key || !control.native_owned?)
    external_ids = bounded(connection.external_accounts.order(:id).limit(MAX_ROWS + 1).pluck(:id))
    lock_rows!(ExternalAccount, external_ids)
    scope = ProviderMigrationMapping.where(external_account_id: external_ids)
    scope = scope.or(ProviderMigrationMapping.where(provider_migration_control_id: control.id, role: "external_account")) if control
    mappings = bounded(scope.order(:id).limit(MAX_ROWS + 1).lock("FOR UPDATE NOWAIT").to_a)
    manifest = @manifests.find { |candidate| candidate.item_type == control&.legacy_type }
    refuse! unless mappings.all? { |mapping| control && manifest && mapping.role == "external_account" &&
      mapping.family_id == @family_id && mapping.provider_migration_control_id == control.id &&
      mapping.legacy_type == manifest.account_type && external_ids.include?(mapping.external_account_id) &&
      mapping.provider_connection_id.nil? && mapping.provider_authorization_id.nil? }
    rows = mappings.map { |mapping| [ mapping.legacy_type, mapping.legacy_id, mapping.external_account_id ] }
    groups = verify_legacy_link_inventory!(connection, rows)
    refuse! if AccountProvider.where(external_account_id: external_ids).exists?
    groups.each do |type, ids|
      refuse! if AccountProvider.where(provider_type: type, provider_id: ids).exists?
      column = Owners::DIRECT_COLUMNS[type]
      refuse! if column && Account.where(column => ids).exists?
    end
    true
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Disconnected source ownership is busy; retry after it finishes", cause: nil
  rescue ActiveRecord::RecordNotFound
    refuse!
  end

  private
    def snapshot
      connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id)
      external_ids = bounded(connection.external_accounts.order(:id).limit(MAX_ROWS + 1).pluck(:id))
      source_mappings = bounded(ProviderMigrationMapping.where(external_account_id: external_ids).order(:id).limit(MAX_ROWS + 1)
        .pluck(:legacy_type, :legacy_id, :external_account_id))
      selected_links = bounded(AccountProvider.where(external_account_id: external_ids).order(:id).limit(MAX_ROWS + 1).to_a)
      verify_legacy_link_inventory!(connection, source_mappings)
      direct = Owners::DIRECT_COLUMNS.flat_map do |type, column|
        ids = source_mappings.select { |row| row.first == type }.map(&:second)
        bounded(Account.where(column => ids).order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id, column), maximum: MAX_ACCOUNTS)
          .map { |id, source_id| { "account_id" => id, "provider_type" => type, "provider_id" => source_id } }
      end
      account_ids = bounded((selected_links.map(&:account_id) + direct.map { |row| row.fetch("account_id") }).uniq.sort, maximum: MAX_ACCOUNTS)
      accounts = Account.where(id: account_ids, family_id: @family_id).select(*ACCOUNT_COLUMNS).order(:id).map(&:attributes)
      refuse! unless accounts.size == account_ids.size
      links = bounded(AccountProvider.where(account_id: account_ids).order(:id).limit(MAX_ROWS + 1).map { |link| link.attributes.slice(*Owners::LINK_COLUMNS) })
      all_direct = accounts.flat_map do |account|
        Owners::DIRECT_COLUMNS.filter_map do |type, column|
          id = account[column]
          { "account_id" => account.fetch("id"), "provider_type" => type, "provider_id" => id } if id
        end
      end
      owners = Owners.capture(family_id: @family_id, links: links, direct_sources: all_direct,
        external_ids: external_ids, connection_ids: [ @connection_id ])
      assert_native_target!(owners, connection: connection)
      selected_ids = selected_links.map(&:id)
      # Every retained policy is included so review cannot silently change the
      # authority to keep, and unknown selected revisions cannot be discarded.
      policies = bounded(Account::SourcePolicy.where(account_id: account_ids).order(:id).limit(MAX_ROWS + 1)
        .select(*POLICY_COLUMNS).map(&:attributes))
      policies.each { |row| refuse! unless row["family_id"] == @family_id }
      holdings = bounded(Holding.where(account_provider_id: selected_ids).order(:id).limit(MAX_ROWS + 1).pluck(:id, :account_id, :account_provider_id))
        .map { |id, account_id, link_id| { "id" => id, "account_id" => account_id, "account_provider_id" => link_id } }
      by_link = selected_links.index_by(&:id)
      refuse! unless holdings.all? { |row| by_link.fetch(row.fetch("account_provider_id")).account_id == row.fetch("account_id") }
      selections = selected_inputs(account_ids)
      permissions = permission_headers(accounts)
      binding = { "connection_id" => connection.id, "family_id" => @family_id, "actor_id" => @actor_id,
        "accounts" => accounts, "owners" => owners.proof, "policies" => policies,
        "selected_link_ids" => selected_ids, "direct" => direct, "holdings" => holdings,
        "selections" => selections, "permissions" => permissions }
      refuse! if JSON.generate(binding).bytesize > MAX_BINDING_BYTES
      { binding: Provider::AccountData::MigrationManifest.copy_value(binding), owners: owners, accounts: accounts,
        policies: policies, selected_link_ids: selected_ids, direct: direct, holdings: holdings, selections: selections }
    end

    def assert_native_target!(owners, connection:)
      controls = owners.proof.fetch("controls")
      refuse! unless controls.all? { |row| (ProviderMigrationControl::LEGACY_STATES + ProviderMigrationControl::NATIVE_STATES).include?(row.fetch("state")) }
      current = controls.find { |row| row["provider_connection_id"] == @connection_id }
      refuse! if current && !ProviderMigrationControl::NATIVE_STATES.include?(current.fetch("state"))
      refuse! if current.nil? && (connection.metadata.key?("legacy_type") || connection.metadata.key?("legacy_id"))
      target_externals = owners.proof.fetch("external_accounts").select { |row| row["provider_connection_id"] == @connection_id }.map { |row| row.fetch("id") }
      owners.proof.fetch("links").each do |link|
        next unless target_externals.include?(link["external_account_id"])
        refuse! unless link["family_id"] == @family_id
      end
    end

    def verify_legacy_link_inventory!(connection, mappings)
      control = ProviderMigrationControl.find_by(provider_connection_id: connection.id)
      groups = mappings.group_by(&:first).transform_values { |rows| rows.map(&:second) }
      if control
        manifest = @manifests.find { |candidate| candidate.item_type == control.legacy_type }
        refuse! unless manifest && control.family_id == @family_id
        live_ids = bounded(manifest.account_type.constantize.where(manifest.account_foreign_key => control.legacy_id)
          .order(:id).limit(MAX_ROWS + 1).pluck(:id))
        groups[manifest.account_type] = ((groups[manifest.account_type] || []) + live_ids).uniq
      end
      expected = mappings.to_h { |type, id, external_id| [ [ type, id ], external_id ] }
      groups.each do |type, ids|
        bounded(AccountProvider.where(provider_type: type, provider_id: ids).order(:id).limit(MAX_ROWS + 1).to_a).each do |link|
          # A legacy-only row cannot escape the selected connection merely by
          # dropping its shared pointer. Disposition is required, not deletion.
          refuse! unless expected[[ type, link.provider_id ]] && link.external_account_id == expected[[ type, link.provider_id ]]
        end
        column = Owners::DIRECT_COLUMNS[type]
        next unless column
        bounded(Account.where(column => ids).order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id, :family_id, column), maximum: MAX_ACCOUNTS).each do |account_id, family_id, source_id|
          external_id = expected[[ type, source_id ]]
          refuse! unless external_id && family_id == @family_id &&
            AccountProvider.exists?(account_id: account_id, external_account_id: external_id, family_id: @family_id)
        end
      end
      groups
    end

    def legacy_items(owners)
      native = owners.proof.fetch("controls").select { |row| ProviderMigrationControl::NATIVE_STATES.include?(row.fetch("state")) }
        .map { |row| row.values_at("legacy_type", "legacy_id") }
      owners.legacy_items.reject { |tuple| native.include?(tuple) }.map do |type, id|
        @legacy_models.fetch(type).find_by!(id: id, family_id: @family_id)
      end
    end

    def lock_sources!(owners)
      %w[legacy_items legacy_accounts].each do |kind|
        rows = owners.proof.fetch(kind)
        rows.reject { |row| row["retired_owner"] }.group_by { |row| row.fetch("type") }.sort.each do |type, sources|
          lock_rows!(@legacy_models.fetch(type), sources.map { |row| row.fetch("id") })
        end
        rows.select { |row| row["retired_owner"] }.sort_by { |row| [ row.fetch("type"), row.fetch("id") ] }.each do |row|
          Provider::AccountData::RetiredOwner.lock_proof!(row.fetch("retired_owner"))
        end
      end
      lock_rows!(ExternalAccount, owners.external_ids)
      lock_rows!(ProviderMigrationMapping, owners.mapping_ids)
      lock_rows!(AccountProvider, owners.proof.fetch("links").map { |row| row.fetch("id") })
    end

    def permission_headers(accounts)
      user_ids = ([ @actor_id ] + accounts.map { |row| row["owner_id"] }).compact.uniq.sort
      users = User.where(id: user_ids).order(:id).pluck(:id, :family_id, :active, :role)
      shares = bounded(AccountShare.where(account_id: accounts.map { |row| row.fetch("id") }, user_id: @actor_id).order(:id)
        .limit(MAX_ACCOUNTS + 1).pluck(:id, :account_id, :user_id, :permission), maximum: MAX_ACCOUNTS)
      { "users" => users, "shares" => shares }
    end

    def lock_permissions!
      user_ids = ([ @actor_id ] + @accounts.map(&:owner_id)).compact.uniq.sort
      lock_rows!(User, user_ids)
      AccountShare.where(account_id: @accounts.map(&:id), user_id: @actor_id).order(:id).lock("FOR UPDATE NOWAIT").load
    end

    def authorize!
      actor = User.find_by(id: @actor_id, family_id: @family_id)
      refuse! unless actor&.active?
      @accounts.each do |account|
        owner = User.find_by(id: account.owner_id) if account.owner_id
        refuse! if account.owner_id && owner&.family_id != @family_id
        refuse! unless actor.accessible_accounts.exists?(account.id) && account.permission_for(actor).in?([ :owner, :full_control ])
      end
    end

    def selected_inputs(account_ids)
      bounded(Account::SyncSource.where(account_id: account_ids).order(:id).limit(MAX_ROWS + 1).to_a).map do |selection|
        input = Account::SyncInput.select(:id, :account_id, :family_id, :resource, :source_batch_id, :provider_sync_id, :payload_digest).find(selection.account_sync_input_id)
        batch = IngestionBatch.select(:id, :family_id, :provider_connection_id, :sync_id).find(input.source_batch_id)
        refuse! unless selection.family_id == @family_id && input.account_id == selection.account_id && input.family_id == @family_id &&
          input.resource == selection.resource && batch.family_id == @family_id && batch.sync_id == input.provider_sync_id && batch.provider_connection_id
        { "id" => selection.id, "account_id" => selection.account_id, "family_id" => selection.family_id,
          "resource" => selection.resource, "account_sync_input_id" => input.id, "source_batch_id" => batch.id,
          "provider_sync_id" => input.provider_sync_id, "payload_digest" => input.payload_digest,
          "provider_connection_id" => batch.provider_connection_id }
      end
    end

    def assert_idle!(owners)
      if Sync.where(syncable_type: "Account", syncable_id: @accounts.map(&:id)).incomplete.exists?
        raise Busy, "Finish account calculations before disconnecting a source"
      end
      ProviderConnection.where(id: owners.connection_ids).each do |connection|
        if connection.lease_owner || connection.lease_expires_at || connection.lease_sync_id ||
            connection.syncs.incomplete.exists? || connection.provider_sync_generations.unfinished.exists?
          raise Busy, "Finish provider work before disconnecting a source"
        end
      end
    end

    def lock_rows!(model, ids)
      expected = ids.uniq.sort
      locked = model.where(id: expected).select(:id).order(:id).lock("FOR UPDATE NOWAIT").map(&:id)
      refuse! unless locked == expected
    end

    def bounded(rows, maximum: MAX_ROWS)
      refuse! if rows.size > maximum
      rows
    end

    def refuse!
      raise Conflict, "Connection links or account management permission changed; reload before continuing", cause: nil
    end
end
