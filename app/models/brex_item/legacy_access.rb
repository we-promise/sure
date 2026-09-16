# Direct legacy consumers join the same permit as Sync dispatch. Transport runs
# outside row transactions; local financial publication rechecks its exact owner.
class BrexItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  LINK_COLUMNS = %i[id account_id family_id external_account_id provider_key lock_version].freeze
  FINANCIAL_COLUMNS = %w[id family_id currency accountable_type accountable_id status].freeze
  SOURCE_COLUMNS = %w[id brex_item_id account_id account_kind currency current_balance available_balance account_limit created_at].freeze

  def self.assert_transport!
    unless ApplicationRecord.connection.open_transactions.zero?
      raise Fence::InvalidSource, "Brex transport must run outside a database transaction"
    end
  end

  def self.with_item(item, operation: :ingest, sync: nil)
    Fence.with_item(item, operation: operation) do |current|
      current.reload
      raise Fence::OwnershipChanged, "Brex source is scheduled for deletion" if current.scheduled_for_deletion?
      current_sync = Fence.scoped_sync!(current, sync)
      yield current, current_sync
    end
  rescue *DENIAL_ERRORS => error
    capture_failure(item, error)
    raise
  end

  def self.with_account(source, operation: :publish)
    unless source.is_a?(BrexAccount) && source.persisted? && !source.destroyed?
      raise Fence::InvalidSource, "Expected a persisted Brex account"
    end
    with_item(source.brex_item, operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ source ]).sole
      current.brex_item = item
      ApplicationRecord.uncached { link_inventory(current) }
      yield current
    end
  end

  def self.transport_context(item)
    Provider::AccountData::RuntimeInputs.fingerprint(item.slice("id", "family_id", "token", "base_url", "sync_start_date"),
      purpose: "brex-legacy-transport/v1")
  end

  def self.verify_transport!(item, expected)
    unless transport_context(item) == expected
      raise Fence::OwnershipChanged, "Brex request configuration changed"
    end
  end

  def self.with_snapshot(item, expected_context: nil)
    expected_context ||= transport_context(item)
    with_item(item) do |current|
      BrexItem.transaction(requires_new: true) do
        fresh = BrexItem.where(id: current.id, family_id: current.family_id).lock("FOR UPDATE NOWAIT").first!
        verify_transport!(fresh, expected_context)
        raise Fence::OwnershipChanged, "Brex source is scheduled for deletion" if fresh.scheduled_for_deletion?
        yield fresh
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Brex snapshot owner changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Brex snapshot is being changed; retry publication", cause: nil
  end

  def self.source_context(source)
    links = link_inventory(source)
    financial = Account.where(id: links[:account_id]).pick(*FINANCIAL_COLUMNS) if links[:account_id]
    Provider::AccountData::RuntimeInputs.fingerprint(
      { source: source.slice(*SOURCE_COLUMNS), links: links, financial: financial,
        raw: source.raw_payload, transactions: source.raw_transactions_payload }, purpose: "brex-legacy-source/v1")
  end

  def self.with_source_snapshot(source, expected_context: nil, expected_item_context: nil)
    expected_context ||= source_context(source)
    with_account(source, operation: :ingest) do |current|
      expected = current.current_account
      if expected
        with_publication(current, expected_account: expected) do |fresh, _financial|
          verify_transport!(fresh.brex_item, expected_item_context) if expected_item_context
          verify_source!(fresh, expected_context)
          yield fresh
        end
      else
        with_snapshot(current.brex_item) do |item|
          fresh = BrexAccount.where(id: current.id, brex_item_id: item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.brex_item = item
          verify_transport!(item, expected_item_context) if expected_item_context
          verify_source!(fresh, expected_context)
          yield fresh
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Brex snapshot source changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Brex snapshot source is being changed; retry publication", cause: nil
  end

  def self.verify_source!(source, expected)
    raise Fence::OwnershipChanged, "Brex source snapshot or binding changed" unless source_context(source) == expected
  end

  def self.with_publication(source, expected_account:)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "Brex publication requires its selected financial account"
    end
    expected = expected_account.attributes.slice(*FINANCIAL_COLUMNS)
    expected_source = source_context(source)
    with_account(source) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        unless captured[:account_id] == expected.fetch("id") && current.brex_item.family_id == expected.fetch("family_id") &&
            source_context(current) == expected_source
          raise Fence::OwnershipChanged, "Brex financial owner changed before publication"
        end
        Account.transaction(requires_new: true) do
          financial = Account.where(id: expected.fetch("id"), family_id: expected.fetch("family_id"))
            .lock("FOR UPDATE NOWAIT").first!
          item = BrexItem.where(id: current.brex_item_id, family_id: financial.family_id).lock("FOR UPDATE NOWAIT").first!
          fresh = BrexAccount.where(id: current.id, brex_item_id: item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.brex_item = item
          ExternalAccount.where(id: captured[:links].filter_map { |row| row.fetch(3) }).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured[:links].map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless !item.scheduled_for_deletion? && %w[active draft disabled].include?(financial.status) &&
              financial.attributes.slice(*FINANCIAL_COLUMNS) == expected && link_inventory(fresh) == captured
            raise Fence::OwnershipChanged, "Brex financial context changed before publication"
          end
          unless source_context(fresh) == expected_source
            raise Fence::OwnershipChanged, "Brex source identity changed before publication"
          end
          # Account validation locks its owner. Avoid waiting in the opposite
          # order to ownership transfer, which already holds that User row.
          User.where(id: financial.owner_id).select(:id).lock("FOR UPDATE NOWAIT").load if financial.owner_id
          fresh.association(:account_provider).target = links.sole
          fresh.association(:account).target = financial
          yield fresh, financial
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Brex publication owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Brex financial context is being changed; retry publication", cause: nil
  end

  def self.link_inventory(source)
    links = AccountProvider.where(provider_type: "BrexAccount", provider_id: source.id).order(:id).pluck(*LINK_COLUMNS)
    family_id = source.brex_item.family_id
    unless links.size <= 1 && links.all? { |row| (row[2].nil? || row[2] == family_id) && (row[4].nil? || row[4] == "brex") }
      raise Fence::OwnershipChanged, "Brex account has conflicting financial links"
    end
    account_id = links.first&.fetch(1)
    if account_id && !Account.where(id: account_id, family_id: family_id).exists?
      raise Fence::OwnershipChanged, "Brex financial account belongs to another family"
    end
    shared = links.filter_map { |link| verify_shared_link!(source, link) if link[3] }
    { account_id: account_id, links: links, shared: shared }
  end

  def self.verify_shared_link!(source, link)
    item = source.brex_item
    external = ExternalAccount.where(id: link[3], family_id: item.family_id, provider_key: "brex")
      .select(:id, :family_id, :provider_key, :provider_connection_id).first!
    connection = ProviderConnection.where(id: external.provider_connection_id, family_id: item.family_id, provider_key: "brex")
      .select(:id, :family_id, :provider_key).first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id)
      .select(:id, :family_id, :provider_key, :legacy_type, :legacy_id, :state, :writer_epoch).first!
    unless link[2] == item.family_id && link[4] == "brex" && control.family_id == item.family_id &&
        control.provider_key == "brex" && control.legacy_type == "BrexItem" && control.legacy_id == item.id && control.legacy_owned?
      raise Fence::OwnershipChanged, "Brex legacy writer no longer owns this shared source"
    end
    mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: item.family_id,
      role: "external_account", legacy_type: "BrexAccount", legacy_id: source.id, external_account_id: external.id)
      .select(:id, :provider_migration_control_id, :legacy_type, :legacy_id, :external_account_id).first!
    [ external.attributes.slice("id", "family_id", "provider_key", "provider_connection_id"), connection.attributes, control.attributes, mapping.attributes ]
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Brex shared source mapping is missing or changed", cause: nil
  end

  def self.capture_failure(item, error)
    DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Brex legacy operation requires retry or review",
      source: name, provider_key: "brex", family_id: item.family_id,
      metadata: { brex_item_id: item.id, error_class: error.class.name })
  rescue StandardError
    nil
  end
  private_class_method :link_inventory, :verify_shared_link!, :capture_failure
end
