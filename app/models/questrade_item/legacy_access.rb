require "digest"

# Direct legacy consumers join the same permit as Sync dispatch. Transport runs
# outside row transactions; local financial publication rechecks its exact owner.
class QuestradeItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  LINK_COLUMNS = %i[id account_id family_id external_account_id provider_key lock_version].freeze
  FINANCIAL_COLUMNS = %w[id family_id currency accountable_type accountable_id owner_id status].freeze
  SOURCE_COLUMNS = %w[id questrade_item_id questrade_account_id currency name account_type account_status
    current_balance cash_balance raw_payload raw_balances_payload raw_holdings_payload raw_activities_payload
    last_holdings_sync last_activities_sync sync_start_date].freeze

  def self.with_item(item, operation: :ingest, sync: nil)
    Fence.with_item(item, operation: operation) do |current|
      raise Fence::OwnershipChanged, "Questrade source is scheduled for deletion" if current.scheduled_for_deletion?
      session = ActiveSupport::IsolatedExecutionState[QuestradeItem::CredentialSession::CONTEXT_KEY]
      if session
        session.assert_owner!(current)
        session.assert_current!
      end
      current_sync = Fence.scoped_sync!(current, sync)
      yield current, current_sync
    end
  rescue *DENIAL_ERRORS => error
    capture_failure(item, error)
    raise
  end

  def self.with_account(source, operation: :publish)
    unless source.is_a?(QuestradeAccount) && source.persisted? && !source.destroyed?
      raise Fence::InvalidSource, "Expected a persisted Questrade account"
    end
    with_item(source.questrade_item, operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ source ]).sole
      unless current.questrade_account_id == source.questrade_account_id
        raise Fence::OwnershipChanged, "Questrade source account identity changed"
      end
      current.questrade_item = item
      ApplicationRecord.uncached { link_inventory(current) }
      yield current
    end
  end

  # Retain before security/transport work. Scheduling fields are deliberately
  # excluded: the delayed request advances its own state through a verifier.
  def self.capture_context(source)
    Digest::SHA256.hexdigest([ source.attributes.slice(*SOURCE_COLUMNS), link_inventory(source) ].to_json).freeze
  end

  def self.with_snapshot(source, expected_context: nil, verifier: nil)
    with_account(source, operation: :ingest) do |current|
      expected_context ||= capture_context(current)
      if current.current_account
        with_publication(current, expected_account: current.current_account, expected_context: expected_context, verifier: verifier) do |fresh, financial|
          yield fresh, financial
        end
      else
        QuestradeAccount.transaction(requires_new: true) do
          item = QuestradeItem.where(id: current.questrade_item_id, family_id: current.questrade_item.family_id).lock("FOR UPDATE NOWAIT").first!
          fresh = item.questrade_accounts.where(id: current.id).lock("FOR UPDATE NOWAIT").first!
          fresh.questrade_item = item
          unless !item.scheduled_for_deletion? && capture_context(fresh) == expected_context && link_inventory(fresh)[:account_id].nil?
            raise Fence::OwnershipChanged, "Questrade snapshot context changed"
          end
          verifier&.call(fresh, nil)
          yield fresh, nil
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Questrade snapshot source is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Questrade snapshot source is being changed; retry publication", cause: nil
  end

  def self.with_publication(source, expected_account:, expected_context: nil, verifier: nil)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "Questrade publication requires its selected financial account"
    end
    expected = expected_account.attributes.slice(*FINANCIAL_COLUMNS)
    expected_source = source.attributes.slice("id", "questrade_item_id", "questrade_account_id")
    with_account(source) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        expected_context ||= capture_context(current)
        unless captured[:account_id] == expected.fetch("id") && current.questrade_item.family_id == expected.fetch("family_id") &&
            current.attributes.slice(*expected_source.keys) == expected_source
          raise Fence::OwnershipChanged, "Questrade financial owner changed before publication"
        end
        Account.transaction(requires_new: true) do
          financial = Account.where(id: expected.fetch("id"), family_id: expected.fetch("family_id"))
            .lock("FOR UPDATE NOWAIT").first!
          item = QuestradeItem.where(id: current.questrade_item_id, family_id: financial.family_id).lock("FOR UPDATE NOWAIT").first!
          fresh = QuestradeAccount.where(id: current.id, questrade_item_id: item.id).lock("FOR UPDATE NOWAIT").first!
          fresh.questrade_item = item
          ExternalAccount.where(id: captured[:links].filter_map { |row| row.fetch(3) }).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured[:links].map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless !item.scheduled_for_deletion? && !financial.pending_deletion? &&
              financial.attributes.slice(*FINANCIAL_COLUMNS) == expected && link_inventory(fresh) == captured &&
              capture_context(fresh) == expected_context
            raise Fence::OwnershipChanged, "Questrade financial context changed before publication"
          end
          unless fresh.attributes.slice(*expected_source.keys) == expected_source
            raise Fence::OwnershipChanged, "Questrade source identity changed before publication"
          end
          # Account validation locks its owner. Avoid waiting in the opposite
          # order to ownership transfer, which already holds that User row.
          User.where(id: financial.owner_id).select(:id).lock("FOR UPDATE NOWAIT").load if financial.owner_id
          fresh.association(:account_provider).target = links.sole
          fresh.association(:account).target = financial
          fresh.association(:linked_account).target = financial
          verifier&.call(fresh, financial)
          yield fresh, financial
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Questrade publication owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Questrade financial context is being changed; retry publication", cause: nil
  end

  def self.link_inventory(source)
    links = AccountProvider.where(provider_type: "QuestradeAccount", provider_id: source.id).order(:id).pluck(*LINK_COLUMNS)
    family_id = source.questrade_item.family_id
    unless links.size <= 1 && links.all? { |row| (row[2].nil? || row[2] == family_id) && (row[4].nil? || row[4] == "questrade") }
      raise Fence::OwnershipChanged, "Questrade account has conflicting financial links"
    end
    account_id = links.first&.fetch(1)
    if account_id && !Account.where(id: account_id, family_id: family_id).exists?
      raise Fence::OwnershipChanged, "Questrade financial account belongs to another family"
    end
    shared = links.filter_map { |link| verify_shared_link!(source, link) if link[3] }
    { account_id: account_id, links: links, shared: shared }
  end

  def self.verify_shared_link!(source, link)
    item = source.questrade_item
    external = ExternalAccount.where(id: link[3], family_id: item.family_id, provider_key: "questrade")
      .select(:id, :family_id, :provider_key, :provider_connection_id).first!
    connection = ProviderConnection.where(id: external.provider_connection_id, family_id: item.family_id, provider_key: "questrade")
      .select(:id, :family_id, :provider_key).first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id)
      .select(:id, :family_id, :provider_key, :legacy_type, :legacy_id, :state, :writer_epoch).first!
    unless link[2] == item.family_id && link[4] == "questrade" && control.family_id == item.family_id &&
        control.provider_key == "questrade" && control.legacy_type == "QuestradeItem" && control.legacy_id == item.id && control.legacy_owned?
      raise Fence::OwnershipChanged, "Questrade legacy writer no longer owns this shared source"
    end
    mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: item.family_id,
      role: "external_account", legacy_type: "QuestradeAccount", legacy_id: source.id, external_account_id: external.id)
      .select(:id, :provider_migration_control_id, :legacy_type, :legacy_id, :external_account_id).first!
    [ external.attributes.slice("id", "family_id", "provider_key", "provider_connection_id"), connection.attributes, control.attributes, mapping.attributes ]
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "Questrade shared source mapping is missing or changed", cause: nil
  end

  def self.capture_failure(item, error)
    DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Questrade legacy operation requires retry or review",
      source: name, provider_key: "questrade", family_id: item.family_id,
      metadata: { questrade_item_id: item.id, error_class: error.class.name })
  rescue StandardError
    nil
  end
  private_class_method :link_inventory, :verify_shared_link!, :capture_failure
end
