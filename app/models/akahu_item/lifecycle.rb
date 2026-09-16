# Browser management holds a legacy permit across remote discovery, then uses
# short financial-account-first transactions to recheck and publish its result.
class AkahuItem::Lifecycle
  Fence = Provider::AccountData::LegacyWriterFence
  Access = AkahuItem::LegacyAccess
  Selection = AkahuItem::Selection
  MAX_ACCOUNTS = Selection::MAX_ACCOUNTS
  MAX_BYTES = 16.megabytes
  SETTINGS = %w[name app_token user_token sync_start_date].freeze

  def self.create(family:, actor:, attributes:)
    AkahuItem.transaction(requires_new: true) do
      current_actor = User.where(id: actor&.id, family_id: family.id).lock("FOR UPDATE NOWAIT").first
      unless current_actor&.active? && current_actor.admin?
        raise Fence::OwnershipChanged, "Akahu connection management permission changed"
      end
      item = family.akahu_items.build(attributes.to_h.stringify_keys.slice(*SETTINGS))
      item.name = I18n.t("akahu_items.provider_panel.default_connection_name") if item.name.blank?
      item.sync_later if item.save
      item
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Akahu connection management is busy", cause: nil
  end

  def initialize(item:, actor:)
    unless item.is_a?(AkahuItem) && item.persisted? && !item.destroyed?
      raise Fence::InvalidSource, "Expected a persisted Akahu connection"
    end
    @item, @item_id, @family_id, @actor_id = item, item.id, item.family_id, actor&.id
  end

  def update_settings(attributes)
    guarded do
      Fence.with_exclusive(@item) do |item|
        locked(item) do |current, _actor|
          verify_legacy!(current, lock: true)
          values = attributes.to_h.stringify_keys.slice(*SETTINGS)
          %w[app_token user_token].each { |key| values.delete(key) if values[key].blank? }
          current.update(values)
          current
        end
      end
    end
  end

  def discover(flow: nil, account_id: nil, setup: false)
    with_item do |item|
      authorize_account!(item, account_id) if account_id
      inventory = Selection.inventory(item)
      transport = Access.transport_context(item)
      sources = bounded_sources(item)
      contexts = sources.to_h { |source| [ source.id, Access.source_context(source) ] }
      Access.assert_transport!
      provider = item.akahu_provider
      refuse! unless provider
      rows = provider.get_accounts
      unless rows.is_a?(Array) && rows.size <= MAX_ACCOUNTS && rows.all? { |row| row.is_a?(Hash) } && rows.to_json.bytesize <= MAX_BYTES
        raise Provider::Akahu::AkahuError.new("Invalid complete Akahu discovery", :invalid_response)
      end
      rows = rows.map(&:with_indifferent_access)
      ids = rows.map { |row| remote_id(row) }
      if ids.any?(&:blank?) || ids.uniq.size != ids.size
        raise Provider::Akahu::AkahuError.new("Invalid Akahu discovery identities", :invalid_response)
      end
      locked(item, account_ids: [ account_id ].compact, inventory: inventory, transport: transport) do |current, actor|
        account = authorize_account!(current, account_id, lock: true) if account_id
        current.upsert_akahu_snapshot!({ items: rows }, expected_context: transport)
        by_remote = sources.index_by(&:account_id)
        rows.each do |row|
          next if row[:name].blank?
          source = by_remote[remote_id(row)] || current.akahu_accounts.build(account_id: remote_id(row))
          source.upsert_akahu_snapshot!(row, expected_context: contexts[source.id], expected_item_context: transport)
        end
        final_inventory = Selection.inventory(current)
        linked_source_ids = final_inventory.fetch(:links).map { |link| link[2] }
        unlinked = bounded_sources(current).reject { |source| linked_source_ids.include?(source.id) }.sort_by { |source| [ source.name, source.id ] }
        already_linked = account && account.account_providers.exists?
        { item: current, accounts: already_linked ? [] : unlinked,
          selection_token: flow && Selection.issue(current, actor: actor, flow: flow, account_id: account_id),
          account_already_linked: !!already_linked }
      end
    end
  end

  def link_accounts(account_ids:, account_type:, selection:)
    verify_selection!(selection, flow: :link_accounts)
    refuse! unless Provider::AkahuAdapter.supported_account_types.include?(account_type)
    ids = Array(account_ids).map(&:to_s).uniq
    refuse! if ids.size > MAX_ACCOUNTS
    with_item(selection: selection) do |item|
      locked(item, selection: selection) do |current, actor|
        sources = bounded_sources(current).index_by(&:id)
        created, linked, invalid = [], [], []
        ids.each do |id|
          source = sources[id]
          refuse! unless source
          if source.name.blank?
            invalid << id
          elsif AccountProvider.exists?(provider: source)
            linked << source.name
          else
            created << create_account(current, actor, source, account_type)
          end
        end
        enqueue_sync!(current) if created.any?
        { created_accounts: created, already_linked_accounts: linked, invalid_accounts: invalid }
      end
    end
  end

  def link_existing_account(account_id:, akahu_account_id:, selection:)
    verify_selection!(selection, flow: :link_existing_account, account_id: account_id)
    with_item(selection: selection) do |item|
      locked(item, selection: selection, account_ids: [ account_id ]) do |current, _actor|
        account = authorize_account!(current, account_id, lock: true)
        next { error: :account_already_linked } if account.account_providers.exists?
        source = bounded_sources(current).find { |candidate| candidate.id == akahu_account_id.to_s }
        next { error: :akahu_account_not_found } unless source
        next { error: :akahu_account_already_linked } if AccountProvider.exists?(provider: source)
        AccountProvider.create!(account: account, provider: source)
        enqueue_sync!(current)
        { account: account }
      end
    end
  end

  def complete_account_setup(account_types:, selection:)
    verify_selection!(selection, flow: :complete_account_setup)
    types = account_types.to_h.stringify_keys
    refuse! if types.size > MAX_ACCOUNTS
    with_item(selection: selection) do |item|
      locked(item, selection: selection) do |current, actor|
        sources = bounded_sources(current).index_by(&:id)
        created, skipped = [], 0
        types.keys.sort.each do |id|
          source = sources[id]
          refuse! unless source
          type = types[id]
          if type.blank? || type == "skip"
            skipped += 1
            next
          end
          next unless Provider::AkahuAdapter.supported_account_types.include?(type)
          next if AccountProvider.exists?(provider: source)
          created << create_account(current, actor, source, type)
        end
        enqueue_sync!(current) if created.any?
        { created_accounts: created, skipped_count: skipped }
      end
    end
  end

  def disconnect(dry_run: false, schedule: true)
    scheduled = nil
    results = guarded do
      Fence.with_exclusive(@item) do |item|
        verify_legacy!(item)
        locked(item) do |current, _actor|
          verify_legacy!(current, lock: true)
          sources = bounded_sources(current)
          selected = AccountProvider.where(provider_type: "AkahuAccount", provider_id: sources.map(&:id)).order(:id).to_a
          selected.map(&:account_id).uniq.each { |id| authorize_account!(current, id, lock: true) }
          result = sources.map do |source|
            { provider_account_id: source.id, name: source.name,
              provider_link_ids: selected.select { |link| link.provider_id == source.id }.map(&:id) }
          end
          next result if dry_run
          refuse! if selected.any?(&:external_account_id?)
          policies = Account::SourcePolicy.where(account_provider_id: selected.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          refuse! if policies.any?
          holdings = Holding.where(account_provider_id: selected.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
          owners = selected.to_h { |link| [ link.id, link.account_id ] }
          refuse! unless holdings.all? { |holding| holding.account_id == owners[holding.account_provider_id] }
          Holding.where(id: holdings.map(&:id)).update_all(account_provider_id: nil)
          selected.each(&:destroy!)
          current.update!(scheduled_for_deletion: true) if schedule
          scheduled = current if schedule
          result
        end
      end
    end
    ActiveRecord.after_all_transactions_commit { DestroyJob.perform_later(scheduled) } if scheduled
    results
  end

  def self.schedule_destroy!(item)
    original_id, original_family_id = item.id.to_s.dup.freeze, item.family_id.to_s.dup.freeze
    current = Fence.with_exclusive(item) do |admitted|
      AkahuItem.transaction(requires_new: true) do
        admitted.lock!("FOR UPDATE NOWAIT")
        control = ProviderMigrationControl.where(legacy_type: "AkahuItem", legacy_id: admitted.id).lock("FOR UPDATE NOWAIT").first
        unless admitted.id == original_id && admitted.family_id == original_family_id && !admitted.scheduled_for_deletion? &&
            (!control || (control.family_id == admitted.family_id && control.provider_key == "akahu" && control.legacy_owned?)) &&
            !AccountProvider.where(provider_type: "AkahuAccount", provider_id: admitted.akahu_accounts.select(:id)).exists?
          raise Fence::OwnershipChanged, "Akahu deletion owner changed or still has linked accounts"
        end
        admitted.update!(scheduled_for_deletion: true)
        admitted
      end
    end
    ActiveRecord.after_all_transactions_commit { DestroyJob.perform_later(current) }
    current
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Akahu deletion is busy", cause: nil
  end

  private
    def with_item(selection: nil)
      guarded do
        Access.with_item(@item, operation: :lifecycle) do |current|
          authorize!(current)
          selection&.verify_actor!(@actor_id)
          selection&.verify!(current)
          yield current
        end
      end
    end

    def locked(item, selection: nil, account_ids: [], inventory: Selection.inventory(item), transport: Access.transport_context(item))
      ids = (account_ids.map(&:to_s) + inventory.fetch(:links).map { |row| row[1] }).uniq.sort
      AkahuItem.transaction(requires_new: true) do
        accounts = Account.where(id: ids).order(:id).lock("FOR UPDATE NOWAIT").to_a
        refuse! unless accounts.size == ids.size && accounts.all? { |account| account.family_id == @family_id && !account.pending_deletion? }
        current = AkahuItem.where(id: item.id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
        User.where(id: (accounts.map(&:owner_id) + [ @actor_id ]).compact.uniq).order(:id).lock("FOR UPDATE NOWAIT").load
        actor = authorize!(current)
        current.akahu_accounts.order(:id).select(:id).limit(MAX_ACCOUNTS + 1).lock("FOR UPDATE NOWAIT").load
        AccountProvider.where(provider_type: "AkahuAccount", provider_id: inventory.fetch(:sources).map(&:first))
          .order(:id).limit(MAX_ACCOUNTS + 1).lock("FOR UPDATE NOWAIT").load
        refuse! unless Selection.inventory(current) == inventory
        Access.verify_transport!(current, transport)
        selection&.verify_actor!(@actor_id)
        selection&.verify!(current)
        yield current, actor
      end
    end

    def authorize!(item)
      actor = User.find_by(id: @actor_id, family_id: @family_id)
      refuse! unless item.id == @item_id && item.family_id == @family_id && !item.scheduled_for_deletion? && actor&.active? && actor.admin?
      actor
    end

    def authorize_account!(item, id, lock: false)
      actor = authorize!(item)
      account = Account.where(id: id, family_id: @family_id).first!
      AccountShare.where(account_id: id, user_id: actor.id).order(:id).lock("FOR UPDATE NOWAIT").load if lock
      refuse! if account.pending_deletion? || !actor.accessible_accounts.exists?(id) || !account.permission_for(actor).in?([ :owner, :full_control ])
      account
    end

    def bounded_sources(item)
      scope = item.akahu_accounts
      headers = scope.order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id, Arel.sql("xmin::text"), Arel.sql("ctid::text"),
        Arel.sql("COALESCE(octet_length(raw_payload::text), 0) + COALESCE(octet_length(raw_transactions_payload::text), 0)"))
      refuse! if headers.size > MAX_ACCOUNTS || headers.sum(&:last) > MAX_BYTES
      return [] if headers.empty?

      # Materialize only the exact versions whose stored bytes were counted.
      # A concurrent expanded cache cannot bypass the read bound between queries.
      tuples = Array.new(headers.size, "(?, ?, ?)").join(", ")
      rows = scope.where("(id::text, xmin::text, ctid::text) IN (VALUES #{tuples})", *headers.flat_map { |row| row.first(3) })
        .order(:id).limit(MAX_ACCOUNTS).to_a
      refuse! unless rows.map(&:id) == headers.map(&:first)
      rows
    end

    def enqueue_sync!(item)
      # Syncable will lock this same visible candidate. Prelock it without
      # waiting while financial/source locks are held so contention rolls back.
      item.syncs.visible.ordered.lock("FOR UPDATE NOWAIT").first
      item.sync_later
    end

    def create_account(item, actor, source, type)
      balance = source.current_balance || 0
      balance = balance.abs if type.in?(%w[CreditCard Loan])
      subtype = if type == "CreditCard"
        "credit_card"
      elsif type.in?(%w[Depository Investment]) && source.suggested_account_type == type
        source.suggested_subtype
      end
      account = Account.create_and_sync({ family: item.family, owner: actor, name: source.name, balance: balance,
        cash_balance: type == "Investment" ? 0 : balance, currency: source.currency.presence || "NZD",
        accountable_type: type, accountable_attributes: subtype.present? ? { subtype: subtype } : {} }, skip_initial_sync: true)
      AccountProvider.create!(account: account, provider: source)
      account
    end

    def remote_id(row)
      value = row[:_id].presence || row[:id].presence
      value.to_s if value.is_a?(String) || value.is_a?(Integer)
    end

    def verify_selection!(selection, flow:, account_id: nil)
      refuse! unless selection.is_a?(Selection)
      selection.verify_actor!(@actor_id)
      selection.verify_target!(flow: flow, account_id: account_id)
    end

    def verify_legacy!(item, lock: false)
      scope = ProviderMigrationControl.where(legacy_type: "AkahuItem", legacy_id: item.id)
      scope = scope.lock("FOR UPDATE NOWAIT") if lock
      control = scope.first
      refuse! if control && (control.family_id != @family_id || control.provider_key != "akahu" || !control.legacy_owned?)
    end

    def guarded
      ApplicationRecord.uncached { yield }
    rescue ActiveRecord::RecordNotFound
      refuse!
    rescue ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "Akahu connection management is busy", cause: nil
    rescue StandardError => error
      begin
        DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Akahu connection management refused",
          source: self.class.name, provider_key: "akahu", family_id: @family_id,
          metadata: { akahu_item_id: @item_id, error_class: error.class.name })
      rescue StandardError
        nil
      end
      raise
    end

    def refuse!
      raise Fence::OwnershipChanged, "Akahu connection or account selection changed; open it again", cause: nil
    end
end
