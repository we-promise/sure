# Ownership admission for direct legacy readers and publishers. Subclasses name
# trusted provider configuration; transport and financial semantics stay outside.
class Provider::AccountData::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  LINK_COLUMNS = %i[id account_id family_id external_account_id provider_key lock_version].freeze
  FINANCIAL_COLUMNS = %w[id family_id currency accountable_type accountable_id status owner_id].freeze

  def self.assert_transport!
    raise Fence::InvalidSource, "Legacy transport must run outside a database transaction" unless ApplicationRecord.connection.open_transactions.zero?
  end

  def self.with_item(item, operation: :ingest, sync: nil)
    unless item.is_a?(item_model) && item.persisted? && !item.destroyed?
      raise Fence::InvalidSource, "Expected the configured persisted legacy item"
    end
    Fence.with_item(item, operation: operation) do |current|
      begin
        current.reload
      rescue ActiveRecord::RecordNotFound
        raise Fence::OwnershipChanged, "Legacy source disappeared during admission", cause: nil
      end
      raise Fence::OwnershipChanged, "Legacy source is scheduled for deletion" if current.scheduled_for_deletion?
      yield current, Fence.scoped_sync!(current, sync)
    end
  rescue *DENIAL_ERRORS => error
    capture_failure(item, error)
    raise
  end

  def self.with_account(source, operation: :publish)
    unless source.is_a?(source_model) && source.persisted? && !source.destroyed?
      raise Fence::InvalidSource, "Expected the configured persisted legacy account"
    end
    with_item(source.public_send(item_association), operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ source ]).sole
      current.association(item_association).target = item
      ApplicationRecord.uncached { link_inventory(current) }
      yield current
    end
  end

  def self.transport_context(item)
    Provider::AccountData::RuntimeInputs.fingerprint(
      { item: item.slice(*transport_columns), timezone: Family.where(id: item.family_id).pick(:timezone) },
      purpose: "#{provider_key}-legacy-transport/v1")
  end

  def self.verify_transport!(item, expected)
    raise Fence::OwnershipChanged, "Legacy request configuration changed" unless transport_context(item) == expected
  end

  def self.with_snapshot(item, expected_context: nil)
    expected_context ||= transport_context(item)
    with_item(item) do |current|
      item_model.transaction(requires_new: true) do
        fresh = item_model.where(id: current.id, family_id: current.family_id).lock("FOR UPDATE NOWAIT").first!
        verify_transport!(fresh, expected_context)
        raise Fence::OwnershipChanged, "Legacy source is scheduled for deletion" if fresh.scheduled_for_deletion?
        yield fresh
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Legacy snapshot owner changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Legacy snapshot is being changed; retry publication", cause: nil
  end

  def self.source_context(source)
    links = link_inventory(source)
    financial = Account.where(id: links[:account_id]).pick(*FINANCIAL_COLUMNS) if links[:account_id]
    Provider::AccountData::RuntimeInputs.fingerprint(
      { source: source.slice(*source_columns), links: links, financial: financial,
        raw: source.raw_payload, transactions: source.raw_transactions_payload }, purpose: "#{provider_key}-legacy-source/v1")
  end

  def self.verify_source!(source, expected)
    raise Fence::OwnershipChanged, "Legacy source snapshot or binding changed" unless source_context(source) == expected
  end

  def self.with_source_snapshot(source, expected_context: nil, expected_item_context: nil)
    expected_context ||= source_context(source)
    expected_item_context ||= transport_context(source.public_send(item_association))
    with_account(source, operation: :ingest) do |current|
      expected = current.current_account
      if expected
        with_publication(current, expected_account: expected) do |fresh, _financial|
          verify_transport!(fresh.public_send(item_association), expected_item_context)
          verify_source!(fresh, expected_context)
          yield fresh
        end
      else
        with_snapshot(current.public_send(item_association), expected_context: expected_item_context) do |item|
          fresh = source_model.where(id: current.id, manifest.account_foreign_key => item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.association(item_association).target = item
          verify_source!(fresh, expected_context)
          yield fresh
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Legacy snapshot source changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Legacy source is being changed; retry publication", cause: nil
  end

  def self.with_publication(source, expected_account:, resource: nil)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "Legacy publication requires its selected financial account"
    end
    unless [ nil, "transactions", "balances" ].include?(resource)
      raise Fence::InvalidSource, "Unsupported legacy publication resource"
    end
    expected = expected_account.attributes.slice(*FINANCIAL_COLUMNS)
    expected_source = source_context(source)
    expected_transport = transport_context(source.public_send(item_association))
    with_account(source) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        unless captured[:account_id] == expected.fetch("id") && current.public_send(item_association).family_id == expected.fetch("family_id") &&
            source_context(current) == expected_source
          raise Fence::OwnershipChanged, "Legacy financial owner changed before publication"
        end
        Account.transaction(requires_new: true) do
          financial = Account.where(id: expected.fetch("id"), family_id: expected.fetch("family_id"))
            .lock("FOR UPDATE NOWAIT").first!
          item = item_model.where(id: current[manifest.account_foreign_key], family_id: financial.family_id).lock("FOR UPDATE NOWAIT").first!
          fresh = source_model.where(id: current.id, manifest.account_foreign_key => item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.association(item_association).target = item
          ExternalAccount.where(id: captured[:links].filter_map { |row| row.fetch(3) }).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured[:links].map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless !item.scheduled_for_deletion? && %w[active draft disabled].include?(financial.status) &&
              financial.attributes.slice(*FINANCIAL_COLUMNS) == expected && link_inventory(fresh) == captured
            raise Fence::OwnershipChanged, "Legacy financial context changed before publication"
          end
          verify_transport!(item, expected_transport)
          verify_source!(fresh, expected_source)
          verify_authority!(financial, links.sole, resource) if resource
          User.where(id: financial.owner_id).select(:id).lock("FOR UPDATE NOWAIT").load if financial.owner_id
          fresh.association(:account_provider).target = links.sole
          fresh.association(:account).target = financial
          fresh.association(:linked_account).target = financial if source_model.reflect_on_association(:linked_account)
          yield fresh, financial
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Legacy publication owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Legacy financial context is being changed; retry publication", cause: nil
  end

  def self.link_inventory(source)
    links = AccountProvider.where(provider_type: manifest.account_type, provider_id: source.id).order(:id).pluck(*LINK_COLUMNS)
    family_id = source.public_send(item_association).family_id
    unless links.size <= 1 && links.all? { |row| (row[2].nil? || row[2] == family_id) && (row[4].nil? || row[4] == provider_key) }
      raise Fence::OwnershipChanged, "Legacy account has conflicting financial links"
    end
    account_id = links.first&.fetch(1)
    if account_id && !Account.where(id: account_id, family_id: family_id).exists?
      raise Fence::OwnershipChanged, "Legacy financial account belongs to another family"
    end
    shared = links.filter_map { |link| verify_shared_link!(source, link) if link[3] }
    { account_id: account_id, links: links, shared: shared }
  end

  def self.verify_shared_link!(source, link)
    item = source.public_send(item_association)
    external = ExternalAccount.where(id: link[3], family_id: item.family_id, provider_key: provider_key)
      .select(:id, :family_id, :provider_key, :provider_connection_id).first!
    connection = ProviderConnection.where(id: external.provider_connection_id, family_id: item.family_id, provider_key: provider_key)
      .select(:id, :family_id, :provider_key).first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id)
      .select(:id, :family_id, :provider_key, :legacy_type, :legacy_id, :state, :writer_epoch).first!
    unless link[2] == item.family_id && link[4] == provider_key && control.family_id == item.family_id &&
        control.provider_key == provider_key && control.legacy_type == manifest.item_type && control.legacy_id == item.id && control.legacy_owned?
      raise Fence::OwnershipChanged, "Legacy writer no longer owns this shared source"
    end
    mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: item.family_id,
      role: "external_account", legacy_type: manifest.account_type, legacy_id: source.id, external_account_id: external.id)
      .select(:id, :provider_migration_control_id, :legacy_type, :legacy_id, :external_account_id).first!
    [ external.attributes.slice("id", "family_id", "provider_key", "provider_connection_id"), connection.attributes, control.attributes, mapping.attributes ]
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Legacy shared source mapping is missing or changed", cause: nil
  end

  def self.verify_authority!(account, link, resource)
    resources = resource == "transactions" ? Account::SourcePolicy::CASH_RESOURCES : [ resource ]
    policies = Account::SourcePolicy.active.where(account: account, resource: resources).order(:resource).lock("FOR UPDATE NOWAIT").to_a
    policies.each do |policy|
      Account::SourcePolicy::Binding.verify_live!(policy: policy)
      raise Fence::OwnershipChanged, "Another source owns legacy publication" unless policy.account_provider_id == link.id
    end
    if policies.empty? && Account::SourcePolicy.where(account: account, resource: resources).exists?
      raise Fence::OwnershipChanged, "Legacy publication has no active retained source selection"
    end
  rescue Account::SourcePolicy::Binding::Conflict
    raise Fence::OwnershipChanged, "Legacy source selection changed", cause: nil
  rescue Account::SourcePolicy::Binding::Busy
    raise Fence::Busy, "Legacy source selection is being changed; retry publication", cause: nil
  end

  def self.capture_failure(item, error)
    DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Legacy operation requires retry or review",
      source: name, provider_key: provider_key, family_id: item.family_id,
      metadata: { legacy_item_id: item.id, error_class: error.class.name })
  rescue StandardError
    nil
  end

  def self.manifest
    Provider::AccountData::MigrationManifest.for(provider_key)
  end

  def self.item_model
    manifest.item_type.constantize
  end

  def self.source_model
    manifest.account_type.constantize
  end

  def self.item_association
    manifest.account_foreign_key.delete_suffix("_id").to_sym
  end

  private_class_method :link_inventory, :verify_shared_link!, :verify_authority!, :capture_failure,
    :manifest, :item_model, :source_model, :item_association
end
