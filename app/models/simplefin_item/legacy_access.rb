# Shared admission for SimpleFIN's direct legacy consumers. It pins the selected
# item before reading credentials or source payloads; no HTTP transaction opens.
class SimplefinItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  DENIAL_ERRORS = [ Fence::OwnershipChanged, Fence::Busy, Fence::InvalidSource ].freeze
  LINK_COLUMNS = %i[id account_id family_id external_account_id provider_key lock_version].freeze
  FINANCIAL_COLUMNS = %w[id family_id currency accountable_type accountable_id].freeze

  def self.with_item(item, operation: :ingest, sync: nil, allow_completed: false)
    Fence.with_item(item, operation: operation) do |current|
      SimplefinItem::ConnectionUpdate.with_item(current) do |locked|
        current_sync = Fence.scoped_sync!(locked, sync, allow_completed: allow_completed)
        yield locked, current_sync
      end
    end
  end

  def self.with_account(account, operation: :publish)
    unless account.is_a?(SimplefinAccount) && account.persisted? && !account.destroyed?
      raise Fence::InvalidSource, "Expected a persisted SimpleFIN account"
    end
    with_item(account.simplefin_item, operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ account ]).sole
      current.simplefin_item = item
      ApplicationRecord.uncached { link_inventory(current) }
      yield current
    end
  end

  # Call after selecting a financial owner, immediately around local publication.
  # Per-entry callers retain short transactions; network/security lookup work must
  # finish outside this boundary. An unlink or relink cannot be silently adopted.
  def self.with_publication(source, expected_account:)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "SimpleFIN publication requires its selected financial account"
    end
    expected = expected_account.attributes.slice(*FINANCIAL_COLUMNS)
    with_account(source) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        unless captured.fetch(:account_id) == expected.fetch("id") && current.simplefin_item.family_id == expected.fetch("family_id")
          raise Fence::OwnershipChanged, "SimpleFIN financial owner changed before publication"
        end
        Account.transaction(requires_new: true) do
          financial = Account.where(id: expected.fetch("id"), family_id: expected.fetch("family_id"))
            .lock("FOR UPDATE NOWAIT").first!
          SimplefinItem.where(id: current.simplefin_item_id, family_id: financial.family_id)
            .select(:id).lock("FOR UPDATE NOWAIT").first!
          fresh = SimplefinAccount.where(id: current.id, simplefin_item_id: current.simplefin_item_id)
            .lock("FOR UPDATE NOWAIT").first!
          fresh.simplefin_item = current.simplefin_item
          ExternalAccount.where(id: captured.fetch(:links).filter_map { |row| row.fetch(3) })
            .select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured.fetch(:links).map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless financial.attributes.slice(*FINANCIAL_COLUMNS) == expected && link_inventory(fresh) == captured
            raise Fence::OwnershipChanged, "SimpleFIN financial context changed before publication"
          end
          # Pin the association objects to the rows actually admitted above.
          # Neither current_account nor a shared import adapter may choose a new
          # financial owner while merchant/entry effects are being committed.
          fresh.association(:account_provider).target = links.first
          fresh.association(:linked_account).target = links.any? ? financial : nil
          fresh.association(:account).target = captured.fetch(:direct).any? ? financial : nil
          yield fresh, financial
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "SimpleFIN publication owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "SimpleFIN financial context is being changed; retry publication", cause: nil
  end

  # Only a current legacy direct FK may create a missing AccountProvider. Never
  # use current_account cached before an unlink. This short write boundary has
  # no transport, normalization, financial update or default-owner callbacks.
  def self.ensure_link(account)
    with_account(account) do |current|
      ApplicationRecord.uncached do
        captured = link_inventory(current)
        next nil if captured.fetch(:account_id).nil?

        Account.transaction(requires_new: true) do
          financial = Account.where(id: captured.fetch(:account_id), family_id: current.simplefin_item.family_id)
            .lock("FOR UPDATE NOWAIT").first!
          SimplefinItem.where(id: current.simplefin_item_id, family_id: financial.family_id)
            .select(:id).lock("FOR UPDATE NOWAIT").first!
          fresh = SimplefinAccount.where(id: current.id, simplefin_item_id: current.simplefin_item_id)
            .lock("FOR UPDATE NOWAIT").first!
          ExternalAccount.where(id: captured.fetch(:links).filter_map { |row| row.fetch(3) })
            .select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
          links = AccountProvider.where(id: captured.fetch(:links).map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          unless link_inventory(fresh) == captured
            raise Fence::OwnershipChanged, "SimpleFIN account linkage changed before repair"
          end
          next links.first if links.any?
          unless captured.fetch(:direct) == [ [ financial.id, financial.family_id ] ]
            raise Fence::OwnershipChanged, "SimpleFIN link repair requires its current direct account reference"
          end

          AccountProvider.create!(account: financial, provider: fresh)
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "SimpleFIN link owner is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "SimpleFIN account linkage is being changed", cause: nil
  end

  def self.link_inventory(source)
    links = AccountProvider.where(provider_type: "SimplefinAccount", provider_id: source.id).order(:id).pluck(*LINK_COLUMNS)
    direct = Account.where(simplefin_account_id: source.id).order(:id).pluck(:id, :family_id)
    ids = (links.map { |row| row.fetch(1) } + direct.map(&:first)).uniq
    family_id = source.simplefin_item.family_id
    unless links.size <= 1 && direct.size <= 1 && ids.size <= 1 &&
        direct.all? { |row| row.fetch(1) == family_id } &&
        links.all? { |row| (row.fetch(2).nil? || row.fetch(2) == family_id) && (row.fetch(4).nil? || row.fetch(4) == "simplefin") }
      raise Fence::OwnershipChanged, "SimpleFIN account has conflicting financial links"
    end
    if ids.any? && !Account.where(id: ids.first, family_id: family_id).exists?
      raise Fence::OwnershipChanged, "SimpleFIN financial account belongs to another family"
    end
    if ids.any?
      siblings = AccountProvider.where(account_id: ids.first)
        .where("provider_type = ? OR provider_key = ?", "SimplefinAccount", "simplefin").order(:id).pluck(:id)
      unless siblings == links.map(&:first)
        raise Fence::OwnershipChanged, "SimpleFIN financial account has another source owner"
      end
    end
    shared = links.filter_map do |row|
      verify_shared_link!(source, row) if row.fetch(3)
    end
    { account_id: ids.first, links: links, direct: direct, shared: shared }
  end

  def self.verify_shared_link!(source, link)
    item = source.simplefin_item
    unless link.fetch(2) == item.family_id && link.fetch(4) == "simplefin"
      raise Fence::OwnershipChanged, "SimpleFIN shared link has inconsistent ownership"
    end
    external = ExternalAccount.where(id: link.fetch(3), family_id: item.family_id, provider_key: "simplefin")
      .select(:id, :family_id, :provider_key, :provider_connection_id).first!
    connection = ProviderConnection.where(id: external.provider_connection_id, family_id: item.family_id, provider_key: "simplefin")
      .select(:id, :family_id, :provider_key).first!
    control = ProviderMigrationControl.where(provider_connection_id: connection.id)
      .select(:id, :family_id, :provider_key, :provider_connection_id, :legacy_type, :legacy_id, :state, :writer_epoch).first!
    unless control.family_id == item.family_id && control.provider_key == "simplefin" &&
        control.legacy_type == "SimplefinItem" && control.legacy_id == item.id && control.legacy_owned?
      raise Fence::OwnershipChanged, "SimpleFIN legacy writer no longer owns this shared source"
    end
    mapping = ProviderMigrationMapping.where(provider_migration_control_id: control.id, family_id: item.family_id,
      role: "external_account", legacy_type: "SimplefinAccount", legacy_id: source.id, external_account_id: external.id)
      .select(:id, :family_id, :provider_migration_control_id, :role, :legacy_type, :legacy_id, :external_account_id).first!
    [ external.attributes, connection.attributes, control.attributes, mapping.attributes ]
  rescue ActiveRecord::RecordNotFound
    raise Fence::OwnershipChanged, "SimpleFIN shared source mapping is missing or changed", cause: nil
  end
  private_class_method :link_inventory, :verify_shared_link!
end
