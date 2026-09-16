# Browser lifecycle commands keep a real legacy permit across discovery, then
# recheck the original credential context under short, nonblocking row locks.
class MercuryItem::Lifecycle
  Fence = Provider::AccountData::LegacyWriterFence
  Access = MercuryItem::LegacyAccess
  Selection = MercuryItem::Selection
  MAX_ACCOUNTS = 1000

  def self.create(family:, actor:, attributes:)
    MercuryItem.transaction(requires_new: true) do
      current_actor = User.where(id: actor&.id, family_id: family.id).lock("FOR UPDATE NOWAIT").first
      unless current_actor&.active? && current_actor.admin?
        raise Fence::OwnershipChanged, "Mercury connection management permission changed"
      end
      item = family.mercury_items.build(attributes.to_h.stringify_keys.slice("name", "token", "base_url", "sync_start_date"))
      item.name ||= "Mercury Connection"
      item.sync_later if item.save
      item
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Mercury connection management is busy", cause: nil
  end

  def initialize(item:, actor:)
    @item, @family_id, @actor_id = item, item.family_id, actor&.id
  end

  def update_settings(attributes)
    # Credential replacement drains in-flight legacy HTTP before changing its
    # owner. This path intentionally does not nest a shared permit inside it.
    ApplicationRecord.uncached do
      Fence.with_exclusive(@item) do |item|
        old_key = Selection.cache_key(item)
        locked(item) do |current, _actor|
          control = ProviderMigrationControl.where(legacy_type: "MercuryItem", legacy_id: current.id).lock("FOR UPDATE NOWAIT").first
          if control && (control.family_id != @family_id || control.provider_key != "mercury" || !control.legacy_owned?)
            refuse!
          end
          current.update(attributes.to_h.stringify_keys.slice("name", "token", "base_url", "sync_start_date"))
          current
        end.tap do |current|
          Rails.cache.delete(old_key) if current.errors.empty? && old_key != Selection.cache_key(current)
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    refuse!
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Mercury connection management is busy", cause: nil
  end

  def discover(flow: nil, account_id: nil, setup: false)
    with_item do |item|
      authorize_account!(item, account_id) if account_id
      rows, cached = setup && item.mercury_accounts.exists? ? [ [], true ] : fetch_accounts(item)
      locked(item) do |current, _actor|
        rows.each { |row| upsert_source(current, row) if account_name(row).present? } if setup
        linked_ids = current.mercury_accounts.joins(:account_provider).pluck(:account_id)
        { item: current, accounts: rows.reject { |row| linked_ids.include?(row[:id].to_s) }, cached: cached,
          selection_token: flow && Selection.issue(current, flow: flow, account_id: account_id) }
      end
    end
  end

  def link_accounts(account_ids:, account_type:, selection:)
    refuse! unless selection.is_a?(Selection) && Provider::MercuryAdapter.supported_account_types.include?(account_type)
    ids = Array(account_ids).map(&:to_s).uniq
    refuse! if ids.size > MAX_ACCOUNTS
    with_item(selection: selection) do |item|
      rows, = fetch_accounts(item, force: true)
      locked(item, selection: selection) do |current, actor|
        created, linked, invalid = [], [], []
        ids.each do |id|
          row = rows.find { |candidate| candidate[:id].to_s == id }
          next unless row
          if account_name(row).blank?
            invalid << id
            next
          end
          source = upsert_source(current, row)
          if AccountProvider.exists?(provider: source)
            linked << source.name
          else
            created << create_account(current, actor, source, account_type, balance: 0)
          end
        end
        current.sync_later if created.any?
        { created_accounts: created, already_linked_accounts: linked, invalid_accounts: invalid }
      end
    end
  end

  def link_existing_account(account_id:, mercury_account_id:, selection:)
    refuse! unless selection.is_a?(Selection)
    with_item(selection: selection) do |item|
      account = authorize_account!(item, account_id)
      next { error: :account_already_linked } if account.account_providers.exists?
      rows, = fetch_accounts(item, force: true)
      row = rows.find { |candidate| candidate[:id].to_s == mercury_account_id.to_s }
      next { error: :mercury_account_not_found } unless row
      next { error: :invalid_account_name } if account_name(row).blank?
      locked(item, selection: selection, account_ids: [ account.id ]) do |current, _actor|
        account = authorize_account!(current, account.id, lock: true)
        next { error: :account_already_linked } if account.account_providers.exists?
        source = upsert_source(current, row)
        next { error: :mercury_account_already_linked } if AccountProvider.exists?(provider: source)
        AccountProvider.create!(account: account, provider: source)
        current.sync_later
        { account: account }
      end
    end
  end

  def complete_account_setup(account_types:, account_subtypes:, selection:)
    refuse! unless selection.is_a?(Selection)
    refuse! if account_types.size > MAX_ACCOUNTS
    with_item(selection: selection) do |item|
      locked(item, selection: selection) do |current, actor|
        created, skipped = [], 0
        account_types.keys.sort.each do |id|
          source = current.mercury_accounts.lock("FOR UPDATE NOWAIT").find_by(id: id)
          refuse! unless source
          type = account_types[id]
          if type.blank? || type == "skip"
            skipped += 1
            next
          end
          next unless Provider::MercuryAdapter.supported_account_types.include?(type)
          next if AccountProvider.exists?(provider: source)
          created << create_account(current, actor, source, type, balance: source.current_balance || 0, subtype: account_subtypes[id])
        end
        current.sync_later if created.any?
        { created_accounts: created, skipped_count: skipped }
      end
    end
  end

  def disconnect
    with_item do |item|
      sources = item.mercury_accounts.order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      refuse! if sources.size > MAX_ACCOUNTS
      links = AccountProvider.where(provider_type: "MercuryAccount", provider_id: sources).order(:id)
      expected = links.pluck(:id, :account_id, :provider_id, :external_account_id, :lock_version)
      locked(item, account_ids: expected.map { |row| row[1] }) do |current, _actor|
        current.mercury_accounts.order(:id).lock("FOR UPDATE NOWAIT").load
        refuse! unless current.mercury_accounts.order(:id).pluck(:id) == sources
        selected = links.lock("FOR UPDATE NOWAIT").to_a
        refuse! unless selected.map { |link| [ link.id, link.account_id, link.provider_id, link.external_account_id, link.lock_version ] } == expected
        # A copied dual source has retained migration provenance. Retiring its
        # connection needs a separate native lifecycle disposition.
        refuse! if selected.any?(&:external_account_id?)
        policies = Account::SourcePolicy.where(account_provider_id: selected.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
        refuse! if policies.any?
        holdings = Holding.where(account_provider_id: selected.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
        owners = selected.to_h { |link| [ link.id, link.account_id ] }
        refuse! unless holdings.all? { |holding| holding.account_id == owners[holding.account_provider_id] }
        Holding.where(id: holdings.map(&:id)).update_all(account_provider_id: nil)
        selected.each(&:destroy!)
        current.destroy_later
        true
      end
    end
  end

  private
    def with_item(operation: :lifecycle, selection: nil)
      ApplicationRecord.uncached do
        Access.with_item(@item, operation: operation) do |current|
          authorize!(current)
          selection&.verify!(current)
          yield current
        end
      end
    rescue ActiveRecord::RecordNotFound
      refuse!
    rescue ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "Mercury connection management is busy", cause: nil
    end

    def authorize!(item, lock: false)
      scope = User.where(id: @actor_id, family_id: @family_id)
      scope = scope.lock("FOR UPDATE NOWAIT") if lock
      actor = scope.first
      refuse! unless item.family_id == @family_id && !item.scheduled_for_deletion? && actor&.active? && actor.admin?
      actor
    end

    def authorize_account!(item, id, lock: false)
      actor = authorize!(item, lock: lock)
      account = Account.where(id: id, family_id: @family_id).first!
      AccountShare.where(account_id: id, user_id: actor.id).order(:id).lock("FOR UPDATE NOWAIT").load if lock
      refuse! if account.pending_deletion? || !actor.accessible_accounts.exists?(id) || !account.permission_for(actor).in?([ :owner, :full_control ])
      account
    end

    def locked(item, selection: nil, account_ids: [])
      fingerprint = Selection.fingerprint(item)
      MercuryItem.transaction(requires_new: true) do
        accounts = Account.where(id: account_ids.uniq).order(:id).lock("FOR UPDATE NOWAIT").to_a
        refuse! unless accounts.size == account_ids.uniq.size && accounts.all? { |account| account.family_id == @family_id && !account.pending_deletion? }
        current = MercuryItem.where(id: item.id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
        actor = authorize!(current, lock: true)
        refuse! unless Selection.fingerprint(current) == fingerprint
        selection&.verify!(current)
        yield current, actor
      end
    end

    def fetch_accounts(item, force: false)
      key = Selection.cache_key(item)
      rows = Rails.cache.read(key) unless force
      cached = !rows.nil?
      unless cached
        Access.assert_transport!
        provider = item.mercury_provider
        refuse! unless provider
        response = provider.get_accounts
        refuse! unless response.is_a?(Hash)
        rows = response.with_indifferent_access[:accounts]
      end
      refuse! unless rows.is_a?(Array) && rows.size <= MAX_ACCOUNTS && rows.all? { |row| row.is_a?(Hash) && row.with_indifferent_access[:id].present? }
      rows = rows.map(&:with_indifferent_access)
      refuse! unless rows.map { |row| row[:id].to_s }.uniq.size == rows.size
      # Re-read after HTTP before caching or returning a signed picker. A raw
      # credential rotation/reparent cannot label an old response as current.
      fresh = MercuryItem.find_by(id: item.id, family_id: @family_id)
      refuse! unless fresh && Selection.fingerprint(fresh) == Selection.fingerprint(item)
      authorize!(fresh)
      Rails.cache.write(key, rows, expires_in: 5.minutes) unless cached
      [ rows, cached ]
    end

    def upsert_source(item, row)
      source = item.mercury_accounts.lock("FOR UPDATE NOWAIT").find_or_initialize_by(account_id: row[:id].to_s)
      source.upsert_mercury_snapshot!(row)
      source
    end

    def create_account(item, actor, source, type, balance:, subtype: nil)
      account = Account.create_and_sync({ family: item.family, owner: actor, name: source.name, balance: balance,
        currency: "USD", accountable_type: type, accountable_attributes: subtype.present? ? { subtype: subtype } : {} }, skip_initial_sync: true)
      AccountProvider.create!(account: account, provider: source)
      account
    end

    def account_name(row)
      row[:nickname].presence || row[:name].presence || row[:legalBusinessName].presence
    end

    def refuse!
      raise Fence::OwnershipChanged, "Mercury connection or account selection changed; open it again", cause: nil
    end
end
