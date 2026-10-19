class EnableBankingItem::DuplicateRepair
  class UnsafeRepairError < StandardError; end

  Result = Data.define(
    :status,
    :pairs,
    :transactions_preserved,
    :duplicate_transactions_removed,
    :transfers_destroyed,
    :transfers_remapped,
    :valuations_moved,
    :valuations_deduplicated,
    :accounts_removed
  )

  UNSAFE_MESSAGE = "These Enable Banking accounts cannot be repaired safely.".freeze
  SOURCE = "enable_banking".freeze

  def initialize(item, user:, pairs:)
    @item = item
    @user = user
    @pairs = normalize_pairs(pairs)
  end

  def call(dry_run: true)
    validate_request!
    result = nil

    item.family.with_lock do
      locked_item = EnableBankingItem.lock.find(item.id)
      records = lock_records(locked_item)

      if already_repaired?(records)
        result = result_for(:already_repaired)
        next
      end

      plans = build_plans(records)
      summary = summary_for(plans)
      if dry_run
        result = Result.new(status: :safe_to_repair, **summary)
      else
        apply_plans!(plans)
        result = Result.new(status: :repaired, **summary)
      end
    end

    result
  end

  private
    attr_reader :item, :user, :pairs

    def normalize_pairs(raw_pairs)
      raise_unsafe unless raw_pairs.is_a?(Array) && raw_pairs.any?

      normalized = raw_pairs.map do |pair|
        values = pair.to_h.with_indifferent_access
        canonical_id = values[:canonical_account_id].to_s
        duplicate_id = values[:duplicate_account_id].to_s
        provider_id = values[:provider_account_id].to_s
        raise_unsafe if canonical_id.blank? || duplicate_id.blank? || provider_id.blank? || canonical_id == duplicate_id

        { canonical_id:, duplicate_id:, provider_id: }
      end

      ids = normalized.flat_map { |pair| [ pair[:canonical_id], pair[:duplicate_id] ] }
      provider_ids = normalized.map { |pair| pair[:provider_id] }
      raise_unsafe unless ids.uniq.size == ids.size && provider_ids.uniq.size == provider_ids.size

      normalized
    rescue NoMethodError, TypeError
      raise_unsafe
    end

    def validate_request!
      raise_unsafe unless item.persisted? && user.present? && user.family_id == item.family_id
    end

    def lock_records(locked_item)
      account_ids = pairs.flat_map { |pair| [ pair[:canonical_id], pair[:duplicate_id] ] }
      provider_ids = pairs.map { |pair| pair[:provider_id] }
      accounts = Account.where(id: account_ids).order(:id).lock.to_a.index_by(&:id)
      provider_accounts = locked_item.enable_banking_accounts.where(id: provider_ids).order(:id).lock.to_a.index_by(&:id)
      account_providers = AccountProvider.where(provider_type: "EnableBankingAccount", provider_id: provider_ids).order(:id).lock.to_a.index_by(&:provider_id)

      AccountShare.where(account_id: account_ids).order(:id).lock.load

      entries = Entry.where(account_id: account_ids).order(:id).lock.to_a
      transaction_ids = entries.select { |entry| entry.entryable_type == "Transaction" }.map(&:entryable_id).uniq
      valuation_ids = entries.select { |entry| entry.entryable_type == "Valuation" }.map(&:entryable_id).uniq
      Transaction.where(id: transaction_ids).order(:id).lock.load
      Valuation.where(id: valuation_ids).order(:id).lock.load

      affected_transfers = Transfer.where(inflow_transaction_id: transaction_ids)
        .or(Transfer.where(outflow_transaction_id: transaction_ids))
        .order(:id).lock.to_a
      RejectedTransfer.where(inflow_transaction_id: transaction_ids)
        .or(RejectedTransfer.where(outflow_transaction_id: transaction_ids))
        .order(:id).lock.load

      {
        accounts:,
        provider_accounts:,
        account_providers:,
        entries: entries.group_by(&:account_id),
        affected_transfers:
      }
    end

    def already_repaired?(records)
      states = pairs.map do |pair|
        canonical = records[:accounts][pair[:canonical_id]]
        duplicate = records[:accounts][pair[:duplicate_id]]
        provider_account = records[:provider_accounts][pair[:provider_id]]
        account_provider = records[:account_providers][pair[:provider_id]]
        next false unless canonical && duplicate.nil? && provider_account && account_provider

        fingerprint = provider_account.reconnection_fingerprint
        account_provider.account_id == canonical.id && fingerprint.present? &&
          canonical.enable_banking_fingerprint == fingerprint &&
          canonical.family_id == item.family_id && can_manage?(canonical)
      end

      return true if states.all?
      raise_unsafe if states.any?

      false
    end

    def build_plans(records)
      plans = pairs.map do |pair|
        canonical = records[:accounts][pair[:canonical_id]]
        duplicate = records[:accounts][pair[:duplicate_id]]
        provider_account = records[:provider_accounts][pair[:provider_id]]
        account_provider = records[:account_providers][pair[:provider_id]]

        validate_pair!(canonical, duplicate, provider_account, account_provider)
        canonical_entries = records[:entries].fetch(canonical.id, [])
        duplicate_entries = records[:entries].fetch(duplicate.id, [])
        transaction_map = build_transaction_map(canonical, duplicate, canonical_entries, duplicate_entries)
        valuation_actions = build_valuation_actions(canonical, duplicate, canonical_entries, duplicate_entries)

        {
          canonical:,
          duplicate:,
          provider_account:,
          account_provider:,
          transaction_map:,
          transaction_count: transaction_map.size,
          valuation_actions:
        }
      end

      map = plans.each_with_object({}) { |plan, result| result.merge!(plan[:transaction_map]) }
      transfer_actions = plan_transfers(records[:affected_transfers], map)
      plans.each { |plan| plan[:transfer_actions] = transfer_actions.select { |action| action[:pair_ids].any? { |id| plan[:transaction_map].key?(id) } } }
      plans
    end

    def validate_pair!(canonical, duplicate, provider_account, account_provider)
      raise_unsafe unless canonical && duplicate && provider_account && account_provider
      raise_unsafe unless provider_account.enable_banking_item_id == item.id
      raise_unsafe unless account_provider.provider_id == provider_account.id && account_provider.account_id == duplicate.id
      raise_unsafe unless canonical.family_id == item.family_id && duplicate.family_id == item.family_id
      raise_unsafe unless canonical.owner_id == duplicate.owner_id && can_manage?(canonical) && can_manage?(duplicate)
      raise_unsafe unless canonical.active? && duplicate.active?
      raise_unsafe unless canonical.currency == duplicate.currency && canonical.currency == provider_account.currency
      raise_unsafe unless canonical.accountable_type.present? && canonical.accountable_type == duplicate.accountable_type
      raise_unsafe unless canonical.accountable&.subtype == duplicate.accountable&.subtype
      raise_unsafe if canonical.accountable.nil? || duplicate.accountable.nil?
      raise_unsafe if canonical.accountable_type == duplicate.accountable_type && canonical.accountable_id == duplicate.accountable_id
      raise_unsafe unless accountable_state(canonical) == accountable_state(duplicate)
      raise_unsafe unless decimal_equal?(canonical.balance, duplicate.balance) && decimal_equal?(canonical.cash_balance, duplicate.cash_balance)
      raise_unsafe unless canonical.exclude_from_reports == duplicate.exclude_from_reports
      raise_unsafe unless canonical.enable_category_matcher == duplicate.enable_category_matcher
      raise_unsafe unless canonical.locked_attributes == duplicate.locked_attributes
      raise_unsafe if duplicate.notes.present? && duplicate.notes != canonical.notes
      raise_unsafe if canonical.enable_banking_fingerprint.present? && canonical.enable_banking_fingerprint != provider_account.reconnection_fingerprint
      raise_unsafe if duplicate.enable_banking_fingerprint.present? && duplicate.enable_banking_fingerprint != provider_account.reconnection_fingerprint

      fingerprint = provider_account.reconnection_fingerprint
      raise_unsafe if fingerprint.blank?
      owner = Account.where(family_id: item.family_id, enable_banking_fingerprint: fingerprint).where.not(id: [ canonical.id, duplicate.id ]).exists?
      raise_unsafe if owner

      raise_unsafe unless canonical.manual?
      raise_unsafe unless duplicate.account_providers.count == 1 && duplicate.account_providers.first.id == account_provider.id
      raise_unsafe if duplicate.plaid_account_id.present? || duplicate.simplefin_account_id.present?
      raise_unsafe if duplicate.account_shares.exists? || duplicate.import_mappings.exists? || duplicate.import_id.present?
      raise_unsafe if duplicate.holdings.exists?
      raise_unsafe if AccountStatement.where(account_id: duplicate.id).or(AccountStatement.where(suggested_account_id: duplicate.id)).exists?
      raise_unsafe if RecurringTransaction.where(account_id: duplicate.id).or(RecurringTransaction.where(destination_account_id: duplicate.id)).exists?
      raise_unsafe if GoalAccount.where(account_id: duplicate.id).exists? || GoalPledge.where(account_id: duplicate.id).exists?
      raise_unsafe if duplicate.logo.attached?
      raise_unsafe if User.where(default_account_id: duplicate.id).exists?
      raise_unsafe if DebugLogEntry.where(account_id: duplicate.id).exists?
      raise_unsafe if FinancekitAccountLineage.where(account_id: duplicate.id).exists?
    end

    def can_manage?(account)
      account.permission_for(user).in?([ :owner, :full_control ])
    end

    def accountable_state(account)
      account.accountable.attributes.except("id", "created_at", "updated_at")
    end

    def decimal_equal?(left, right)
      left.present? && right.present? && left.to_d == right.to_d
    end

    def build_transaction_map(canonical, duplicate, canonical_entries, duplicate_entries)
      canonical_transactions = provider_transactions(canonical, canonical_entries)
      duplicate_transactions = provider_transactions(duplicate, duplicate_entries)
      canonical_by_identity = unique_transactions_by_identity!(canonical_transactions)
      duplicate_by_identity = unique_transactions_by_identity!(duplicate_transactions)
      raise_unsafe unless canonical_by_identity.keys.to_set == duplicate_by_identity.keys.to_set

      duplicate_by_identity.each_with_object({}) do |(identity, duplicate_entry), result|
        canonical_entry = canonical_by_identity.fetch(identity)
        raise_unsafe unless transaction_state(canonical_entry) == transaction_state(duplicate_entry)
        result[duplicate_entry.entryable_id] = canonical_entry.entryable_id
      end
    end

    def provider_transactions(account, entries)
      entries.reject { |entry| entry.entryable_type == "Valuation" }.tap do |transactions|
        raise_unsafe unless transactions.all? do |entry|
          entry.entryable_type == "Transaction" && entry.source == SOURCE && entry.external_id.present? &&
            entry.currency == account.currency && entry.idempotency_key.nil? && entry.plaid_id.nil? &&
            entry.import_id.nil? && entry.reconciled_at.nil? && entry.reconciled_by_statement_id.nil? &&
            entry.parent_entry_id.nil? && !entry.split_parent? && !entry.excluded? && !entry.user_modified? &&
            !entry.import_locked? && entry.locked_attributes.blank? && entry.entryable&.locked_attributes.blank? &&
            entry.recurring_allocations.empty?
        end
      end
    end

    def unique_transactions_by_identity!(entries)
      entries.each_with_object({}) do |entry, result|
        identity = [ entry.source, entry.external_id ]
        raise_unsafe if result.key?(identity)

        transaction = entry.entryable
        raise_unsafe unless transaction.is_a?(Transaction) && transaction.transfer_id.nil?
        raise_unsafe if GoalPledge.where(matched_transaction_id: transaction.id).exists?
        raise_unsafe if FinancekitTransaction.where(entry_id: entry.id).exists?
        raise_unsafe if RecurringMatchRejection.where(entry_id: entry.id).exists?
        raise_unsafe if RecurringPriceChange.where(entry_id: entry.id).exists?

        result[identity] = entry
      end
    end

    def transaction_state(entry)
      transaction = entry.entryable
      {
        date: entry.date,
        amount: entry.amount,
        currency: entry.currency,
        name: entry.name,
        notes: entry.notes,
        excluded: entry.excluded?,
        user_modified: entry.user_modified?,
        import_locked: entry.import_locked?,
        locked_attributes: entry.locked_attributes.deep_stringify_keys,
        transaction_external_id: transaction.external_id,
        category_id: transaction.category_id,
        merchant_id: transaction.merchant_id,
        kind: transaction.kind,
        investment_activity_label: transaction.investment_activity_label,
        extra: transaction.extra.deep_stringify_keys,
        transaction_locked_attributes: transaction.locked_attributes.deep_stringify_keys,
        tags: transaction.tags.ids.sort,
        attachments: attachment_state(transaction)
      }
    end

    def attachment_state(transaction)
      transaction.attachments.map do |attachment|
        [ attachment.filename.to_s, attachment.content_type, attachment.byte_size, attachment.blob.checksum ]
      end.sort
    end

    def build_valuation_actions(canonical, duplicate, canonical_entries, duplicate_entries)
      canonical_valuations = valuations(canonical, canonical_entries)
      duplicate_valuations = valuations(duplicate, duplicate_entries)
      validate_valuations!(canonical_valuations + duplicate_valuations)

      canonical_by_date = canonical_valuations.index_by(&:date)
      duplicate_by_date = duplicate_valuations.index_by(&:date)
      actions = []

      validate_anchor_counts!(canonical_valuations)
      validate_anchor_counts!(duplicate_valuations)

      canonical_opening = canonical_valuations.find { |entry| entry.entryable.opening_anchor? }
      duplicate_opening = duplicate_valuations.find { |entry| entry.entryable.opening_anchor? }
      if canonical_opening && duplicate_opening && canonical_opening.date != duplicate_opening.date
        raise_unsafe
      end

      canonical_current = canonical_valuations.find { |entry| entry.entryable.current_anchor? }
      duplicate_current = duplicate_valuations.find { |entry| entry.entryable.current_anchor? }
      handled_duplicate_ids = Set.new

      if canonical_current && duplicate_current
        if duplicate_current.date == canonical_current.date
          raise_unsafe unless same_valuation_state?(canonical_current, duplicate_current)
          actions << { kind: :delete_valuation, entry: duplicate_current }
          handled_duplicate_ids << duplicate_current.id
        elsif duplicate_current.date > canonical_current.date
          duplicate_reconciliation = duplicate_by_date[canonical_current.date]
          raise_unsafe unless duplicate_reconciliation&.entryable&.reconciliation?
          raise_unsafe unless same_anchor_progression_state?(canonical_current, duplicate_reconciliation, canonical)
          actions << { kind: :convert_current_anchor, entry: canonical_current }
          actions << { kind: :delete_valuation, entry: duplicate_reconciliation }
          actions << { kind: :move_valuation, entry: duplicate_current, canonical: }
          handled_duplicate_ids << duplicate_reconciliation.id
          handled_duplicate_ids << duplicate_current.id
        else
          raise_unsafe
        end
      end

      duplicate_valuations.each do |duplicate_entry|
        next if handled_duplicate_ids.include?(duplicate_entry.id)

        canonical_entry = canonical_by_date[duplicate_entry.date]
        if canonical_entry
          raise_unsafe unless same_valuation_state?(canonical_entry, duplicate_entry)
          actions << { kind: :delete_valuation, entry: duplicate_entry }
        else
          if duplicate_entry.entryable.opening_anchor? && canonical_opening
            raise_unsafe
          end
          if duplicate_entry.entryable.current_anchor? && canonical_current
            raise_unsafe
          end
          actions << { kind: :move_valuation, entry: duplicate_entry, canonical: canonical }
        end
      end

      actions
    end

    def valuations(account, entries)
      entries.select { |entry| entry.entryable_type == "Valuation" }.tap do |rows|
        raise_unsafe unless rows.all? { |entry| entry.entryable.is_a?(Valuation) && entry.currency == account.currency }
      end
    end

    def validate_anchor_counts!(entries)
      raise_unsafe if entries.count { |entry| entry.entryable.opening_anchor? } > 1
      raise_unsafe if entries.count { |entry| entry.entryable.current_anchor? } > 1
    end

    def validate_valuations!(entries)
      raise_unsafe unless entries.all? do |entry|
        entry.import_id.nil? && entry.reconciled_at.nil? && entry.reconciled_by_statement_id.nil? &&
          entry.parent_entry_id.nil? && !entry.split_parent? && !entry.excluded? && !entry.user_modified? &&
          !entry.import_locked? && entry.locked_attributes.blank? && entry.entryable.locked_attributes.blank?
      end
    end

    def same_valuation_state?(left, right)
      left.entryable.kind == right.entryable.kind &&
        left.date == right.date && left.amount == right.amount && left.currency == right.currency &&
        left.notes == right.notes && left.name == right.name &&
        left.excluded? == right.excluded? && left.user_modified? == right.user_modified? &&
        left.import_locked? == right.import_locked? && left.locked_attributes == right.locked_attributes &&
        left.entryable.locked_attributes == right.entryable.locked_attributes
    end

    def same_anchor_progression_state?(current, reconciliation, canonical)
      expected_current_name = Valuation.build_current_anchor_name(canonical.accountable_type)
      expected_reconciliation_name = Valuation.build_reconciliation_name(canonical.accountable_type)
      current.entryable.current_anchor? && reconciliation.entryable.reconciliation? &&
        current.date == reconciliation.date && current.amount == reconciliation.amount &&
        current.currency == reconciliation.currency && current.notes == reconciliation.notes &&
        current.name == expected_current_name && reconciliation.name == expected_reconciliation_name &&
        current.locked_attributes.blank? && reconciliation.locked_attributes.blank? &&
        current.entryable.locked_attributes.blank? && reconciliation.entryable.locked_attributes.blank?
    end

    def plan_transfers(transfers, transaction_map)
      mapped_duplicate_ids = transaction_map.keys.to_set
      rejected = RejectedTransfer.where(inflow_transaction_id: mapped_duplicate_ids.to_a)
        .or(RejectedTransfer.where(outflow_transaction_id: mapped_duplicate_ids.to_a))
      raise_unsafe if rejected.exists?

      affected = transfers.select do |transfer|
        mapped_duplicate_ids.include?(transfer.inflow_transaction_id) || mapped_duplicate_ids.include?(transfer.outflow_transaction_id)
      end
      return [] if affected.empty?

      actions = []
      proposed_pairs = Set.new
      affected.each do |transfer|
        raise_unsafe if transfer.fee_transactions.exists?

        original_pair = [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
        inflow_id = transaction_map.fetch(transfer.inflow_transaction_id, transfer.inflow_transaction_id)
        outflow_id = transaction_map.fetch(transfer.outflow_transaction_id, transfer.outflow_transaction_id)
        inflow = Transaction.find(inflow_id)
        outflow = Transaction.find(outflow_id)
        same_account = inflow.entry.account_id == outflow.entry.account_id

        if same_account
          raise_unsafe unless transfer.pending?
          actions << { kind: :destroy_transfer, transfer:, pair_ids: [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ] }
          next
        end

        next if inflow_id == transfer.inflow_transaction_id && outflow_id == transfer.outflow_transaction_id

        pair = [ inflow_id, outflow_id ]
        raise_unsafe if proposed_pairs.include?(pair)
        proposed_pairs << pair
        raise_unsafe if Transfer.where(inflow_transaction_id: inflow_id).where.not(id: transfer.id).exists?
        raise_unsafe if Transfer.where(outflow_transaction_id: outflow_id).where.not(id: transfer.id).exists?
        raise_unsafe if RejectedTransfer.exists?(inflow_transaction_id: inflow_id, outflow_transaction_id: outflow_id)

        transfer.inflow_transaction = inflow
        transfer.outflow_transaction = outflow
        raise_unsafe unless transfer.valid?
        actions << { kind: :remap_transfer, transfer:, inflow:, outflow:, pair_ids: original_pair }
      end

      actions
    end

    def apply_plans!(plans)
      transfer_actions = plans.flat_map { |plan| plan[:transfer_actions] }.uniq { |action| action[:transfer].id }
      transfer_actions.each do |action|
        case action[:kind]
        when :destroy_transfer
          action[:transfer].destroy!
        when :remap_transfer
          action[:transfer].update!(inflow_transaction: action[:inflow], outflow_transaction: action[:outflow])
        end
      end

      plans.each do |plan|
        plan[:valuation_actions].each do |action|
          case action[:kind]
          when :delete_valuation
            action[:entry].destroy!
          when :move_valuation
            action[:entry].update!(account: action[:canonical])
          when :convert_current_anchor
            action[:entry].entryable.update!(kind: "reconciliation")
            action[:entry].update!(name: Valuation.build_reconciliation_name(plan[:canonical].accountable_type))
          end
        end
      end

      plans.each do |plan|
        canonical = plan[:canonical]
        duplicate = plan[:duplicate]
        account_provider = plan[:account_provider]
        duplicate.update!(enable_banking_fingerprint: nil) if duplicate.enable_banking_fingerprint.present?
        account_provider.update!(account: canonical)
        canonical.update!(balance: duplicate.balance, cash_balance: duplicate.cash_balance)
      end

      plans.each do |plan|
        duplicate = plan[:duplicate]
        duplicate.mark_for_deletion!
        duplicate.destroy!
      end
    end

    def summary_for(plans)
      actions = plans.flat_map { |plan| plan[:transfer_actions] }.uniq { |action| action[:transfer].id }
      valuation_actions = plans.flat_map { |plan| plan[:valuation_actions] }
      {
        pairs: plans.size,
        transactions_preserved: plans.sum { |plan| plan[:transaction_count] },
        duplicate_transactions_removed: plans.sum { |plan| plan[:transaction_count] },
        transfers_destroyed: actions.count { |action| action[:kind] == :destroy_transfer },
        transfers_remapped: actions.count { |action| action[:kind] == :remap_transfer },
        valuations_moved: valuation_actions.count { |action| action[:kind] == :move_valuation },
        valuations_deduplicated: valuation_actions.count { |action| action[:kind] == :delete_valuation },
        accounts_removed: plans.size
      }
    end

    def result_for(status)
      Result.new(
        status:,
        pairs: pairs.size,
        transactions_preserved: 0,
        duplicate_transactions_removed: 0,
        transfers_destroyed: 0,
        transfers_remapped: 0,
        valuations_moved: 0,
        valuations_deduplicated: 0,
        accounts_removed: 0
      )
    end

    def raise_unsafe
      raise UnsafeRepairError, I18n.t("enable_banking_items.errors.duplicate_repair_unsafe", default: UNSAFE_MESSAGE)
    end
end
