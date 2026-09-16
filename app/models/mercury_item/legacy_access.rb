# Direct legacy consumers join the same permit as Sync dispatch. Transport runs
# outside row transactions; local financial publication rechecks its exact owner.
class MercuryItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  LINK_COLUMNS = %i[id account_id family_id external_account_id provider_key lock_version].freeze
  FINANCIAL_COLUMNS = %w[id family_id currency accountable_type accountable_id].freeze

  def self.assert_transport!
    unless ApplicationRecord.connection.open_transactions.zero?
      raise Fence::InvalidSource, "Mercury transport must run outside a database transaction"
    end
  end

  def self.with_item(item, operation: :ingest, sync: nil)
    Fence.with_item(item, operation: operation) do |current|
      raise Fence::OwnershipChanged, "Mercury source is scheduled for deletion" if current.scheduled_for_deletion?
      current_sync = Fence.scoped_sync!(current, sync)
      yield current, current_sync
    end
  rescue *DENIAL_ERRORS => error
    capture_failure(item, error)
    raise
  end

  def self.with_account(source, operation: :publish)
    unless source.is_a?(MercuryAccount) && source.persisted? && !source.destroyed?
      raise Fence::InvalidSource, "Expected a persisted Mercury account"
    end
    with_item(source.mercury_item, operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ source ]).sole
      current.mercury_item = item
      ApplicationRecord.uncached { link_inventory(current) }
      yield current
    end
  end

  def self.with_publication(source, expected_account:)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "Mercury publication requires its selected financial account"
    end
    expected = expected_account.attributes.slice(*FINANCIAL_COLUMNS)
    expected_source = source.attributes.slice("id", "mercury_item_id", "account_id")
    with_account(source) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        unless captured[:account_id] == expected.fetch("id") && current.mercury_item.family_id == expected.fetch("family_id") &&
            current.attributes.slice(*expected_source.keys) == expected_source
          raise Fence::OwnershipChanged, "Mercury financial owner changed before publication"
        end
        Account.transaction(requires_new: true) do
          financial = Account.where(id: expected.fetch("id"), family_id: expected.fetch("family_id"))
            .lock("FOR UPDATE NOWAIT").first!
          item = MercuryItem.where(id: current.mercury_item_id, family_id: financial.family_id).lock("FOR UPDATE NOWAIT").first!
          fresh = MercuryAccount.where(id: current.id, mercury_item_id: item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.mercury_item = item
          ExternalAccount.where(id: captured[:links].filter_map { |row| row.fetch(3) }).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured[:links].map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless !item.scheduled_for_deletion? && !financial.pending_deletion? &&
              financial.attributes.slice(*FINANCIAL_COLUMNS) == expected && link_inventory(fresh) == captured
            raise Fence::OwnershipChanged, "Mercury financial context changed before publication"
          end
          unless fresh.attributes.slice(*expected_source.keys) == expected_source
            raise Fence::OwnershipChanged, "Mercury source identity changed before publication"
          end
          # Account validation locks its owner. Avoid waiting in the opposite
          # order to ownership transfer, which already holds that User row.
          User.where(id: financial.owner_id).select(:id).lock("FOR UPDATE NOWAIT").load if financial.owner_id
          fresh.association(:account_provider).target = links.sole
          fresh.association(:account).target = financial
          fresh.association(:linked_account).target = financial
          yield fresh, financial
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Mercury publication owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Mercury financial context is being changed; retry publication", cause: nil
  end

  def self.link_inventory(source)
    links = AccountProvider.where(provider_type: "MercuryAccount", provider_id: source.id).order(:id).pluck(*LINK_COLUMNS)
    family_id = source.mercury_item.family_id
    unless links.size <= 1 && links.all? { |row| (row[2].nil? || row[2] == family_id) && (row[4].nil? || row[4] == "mercury") }
      raise Fence::OwnershipChanged, "Mercury account has conflicting financial links"
    end
    account_id = links.first&.fetch(1)
    if account_id && !Account.where(id: account_id, family_id: family_id).exists?
      raise Fence::OwnershipChanged, "Mercury financial account belongs to another family"
    end
    shared = links.filter_map { |link| verify_shared_link!(source, link) if link[3] }
    { account_id: account_id, links: links, shared: shared }
  end

  def self.verify_shared_link!(source, link)
    item = source.mercury_item
    external = ExternalAccount.where(id: link[3], family_id: item.family_id, provider_key: "mercury")
      .select(:id, :family_id, :provider_key, :provider_connection_id).first!
    connection = ProviderConnection.where(id: external.provider_connection_id, family_id: item.family_id, provider_key: "mercury")
      .select(:id, :family_id, :provider_key).first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id)
      .select(:id, :family_id, :provider_key, :legacy_type, :legacy_id, :state, :writer_epoch).first!
    unless link[2] == item.family_id && link[4] == "mercury" && control.family_id == item.family_id &&
        control.provider_key == "mercury" && control.legacy_type == "MercuryItem" && control.legacy_id == item.id && control.legacy_owned?
      raise Fence::OwnershipChanged, "Mercury legacy writer no longer owns this shared source"
    end
    mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: item.family_id,
      role: "external_account", legacy_type: "MercuryAccount", legacy_id: source.id, external_account_id: external.id)
      .select(:id, :provider_migration_control_id, :legacy_type, :legacy_id, :external_account_id).first!
    [ external.attributes.slice("id", "family_id", "provider_key", "provider_connection_id"), connection.attributes, control.attributes, mapping.attributes ]
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Mercury shared source mapping is missing or changed", cause: nil
  end

  def self.capture_failure(item, error)
    DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Mercury legacy operation requires retry or review",
      source: name, provider_key: "mercury", family_id: item.family_id,
      metadata: { mercury_item_id: item.id, error_class: error.class.name })
  rescue StandardError
    nil
  end
  private_class_method :link_inventory, :verify_shared_link!, :capture_failure
end
