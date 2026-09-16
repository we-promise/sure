# Legacy cleanup only. Native identities and corroborating evidence are handled
# by shared ingestion; an old compatibility source label cannot authorize them.
class SimplefinAccount::PendingCleanup
  Fence = SimplefinItem::LegacyAccess::Fence
  PAGE_SIZE = 100
  CANDIDATE_LIMIT = 100
  MAX_CACHE_RECORDS = 20_000
  MAX_CACHE_BYTES = 16.megabytes
  SOURCE = "simplefin".freeze

  def initialize(source, expected_account:)
    unless expected_account.is_a?(Account) && expected_account.persisted? && !expected_account.destroyed?
      raise Fence::InvalidSource, "SimpleFIN cleanup requires its selected financial account"
    end
    @source = source
    @expected_account = expected_account
  end

  # Each outcome is yielded only after all enclosing transactions commit. Ordinary
  # row failures remain retryable; migration/ownership denials abort the command.
  def call(&listener)
    successful = true
    SimplefinItem::LegacyAccess.with_account(@source) do |source|
      expected = Account.instantiate(@expected_account.attributes.deep_dup)
      retained = source.read_attribute_before_type_cast(:raw_transactions_payload)
      source_type = source.account_type
      selection = selection_for(source, expected)
      observed_on = Date.current
      publish = lambda do |&work|
        SimplefinItem::LegacyAccess.with_publication(source, expected_account: expected) do |fresh, account|
          unless selection_for(fresh, account) == selection && fresh.account_type == source_type &&
              fresh.read_attribute_before_type_cast(:raw_transactions_payload) == retained
            raise Fence::OwnershipChanged, "SimpleFIN cleanup source changed before publication"
          end
          verify_authority!(fresh, account)
          work.call(account)
        end
      end
      # Admission is checked even for an empty scan, before importer debounce.
      publish.call { |_account| }
      # Check stored size before decrypting/decoding the retained history. The
      # byte check includes encryption overhead; large histories stay unresolved.
      if (retained.is_a?(String) && retained.bytesize > MAX_CACHE_BYTES) ||
          (!retained.is_a?(String) && retained.to_json.bytesize > MAX_CACHE_BYTES)
        return incomplete_cache(source, expected, &listener)
      end
      cache = source.raw_transactions_payload
      unless cache.nil? || (cache.is_a?(Array) && cache.size <= MAX_CACHE_RECORDS)
        return incomplete_cache(source, expected, &listener)
      end
      retained = retained.deep_dup
      identities = identities_for(source, cache)
      identities.keys.each_slice(PAGE_SIZE) do |keys|
        ids = pending_entries(expected).where(external_id: keys).order(:id).pluck(:id)

        ids.each do |id|
          begin
            outcomes = publish.call { |account| process_entry(account, id, identities, observed_on) }
          rescue *SimplefinItem::LegacyAccess::DENIAL_ERRORS
            raise
          rescue => error
            successful = false
            DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
              message: "SimpleFIN pending cleanup failed; the row was rolled back",
              source: self.class.name, provider_key: SOURCE, family: source.simplefin_item.family,
              account_provider: source.account_provider,
              metadata: { simplefin_account_id: source.id, entry_id: id, error_class: error.class.name })
            outcomes = [ { kind: :error, account_id: expected.id, account_name: expected.name,
              entry_id: id, error: "#{error.class.name}: pending cleanup failed" } ]
          end
          Array(outcomes).each { |outcome| emit(outcome, &listener) }
        end
      end
      unmatched = publish.call do |account|
        pending_entries(account).where("entries.date < ?", observed_on - 8)
          .where("transactions.extra -> 'potential_posted_match' IS NULL").count
      end
      emit({ kind: :unmatched, account_id: expected.id, account_name: expected.name, count: unmatched }, &listener)
      emit({ kind: :finished, account_id: expected.id, success: successful }, &listener)
    end
    successful
  end

  private
    def emit(outcome, &listener)
      return unless listener
      ActiveRecord.after_all_transactions_commit { listener.call(outcome) }
    end

    def incomplete_cache(source, account, &listener)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "SimpleFIN pending cleanup requires a bounded retained transaction cache",
        source: self.class.name, provider_key: SOURCE, family: source.simplefin_item.family,
        account_provider: source.account_provider, metadata: { simplefin_account_id: source.id })
      emit({ kind: :error, account_id: account.id, account_name: account.name,
        error: "Retained transaction cache exceeds cleanup limits or has an invalid shape" }, &listener)
      emit({ kind: :finished, account_id: account.id, success: false }, &listener)
      false
    end

    def selection_for(source, account)
      { link: source.account_provider&.attributes&.slice(*SimplefinItem::LegacyAccess::LINK_COLUMNS.map(&:to_s)),
        direct_source_id: account.simplefin_account_id }
    end

    def verify_authority!(source, account)
      selected = Account::SourcePolicy.active.where(account: account, resource: Account::SourcePolicy::CASH_RESOURCES)
        .pluck(:account_provider_id).uniq
      unless selected.empty? || selected == [ source.account_provider&.id ]
        raise Fence::OwnershipChanged, "Another source owns SimpleFIN cleanup cash movements"
      end
    end

    def entries(account)
      account.entries.where(source: SOURCE, entryable_type: "Transaction", excluded: false)
        .where.not(external_id: [ nil, "" ])
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
    end

    def pending_entries(account)
      entries(account).where("transactions.extra -> 'simplefin' ->> 'pending' IN (?)", %w[true 1])
    end

    def posted_entries(account)
      entries(account).where(Transaction::PENDING_PROVIDERS.map { |key|
        "COALESCE(transactions.extra -> '#{key}' ->> 'pending', 'false') NOT IN ('true', '1')"
      }.join(" AND "))
    end

    def identities_for(source, cache)
      Array(cache).each_with_object({}) do |raw, identities|
        next unless raw.is_a?(Hash)
        id = raw["id"] || raw[:id]
        next if id.blank?
        key = "simplefin_#{id}"
        # Duplicate or malformed cache rows cannot establish ownership, even if
        # their apparent economics happen to agree.
        if identities.key?(key)
          identities[key] = nil
          next
        end
        identities[key] = nil
        amount = raw["amount"] || raw[:amount]
        next unless (amount.is_a?(String) && amount.present?) || amount.is_a?(Numeric)
        begin
          value = SimplefinEntry::Processor.new(raw, simplefin_account: source).identity_attributes
          identities[key] = value if value.fetch(:amount).finite?
        rescue ArgumentError, TypeError
          # Keep this identity unresolved; never manufacture zero or a date.
        end
      end
    end

    def candidate_ids(account, pending)
      posted = posted_entries(account).where(currency: pending.currency).where.not(id: pending.id)
      exact = posted.where(amount: pending.amount, date: pending.date..(pending.date + 8)).order(:id).limit(2).pluck(:id)
      fuzzy = posted.where(date: pending.date..(pending.date + 3))
        .where("ABS(entries.amount) BETWEEN ? AND ?", pending.amount.abs, pending.amount.abs * BigDecimal("1.25"))
        .where(pending.amount.negative? ? "entries.amount < 0" : "entries.amount > 0")
        .order(:id).limit(CANDIDATE_LIMIT + 1).pluck(:id)
      reverse = if exact.one?
        posted_date = Entry.where(id: exact.first).pick(:date)
        pending_entries(account).where(amount: pending.amount, currency: pending.currency,
          date: (posted_date - 8)..posted_date).order(:id).limit(2).pluck(:id)
      else
        []
      end
      { exact: exact, fuzzy: fuzzy, reverse: reverse }
    end

    def process_entry(account, id, identities, observed_on)
      pending = pending_entries(account).find_by(id: id)
      return [] unless pending
      captured = candidate_ids(account, pending)
      ids = ([ id ] + captured.values.flatten).uniq.sort
      locked = account.entries.where(id: ids).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
      transactions = Transaction.where(id: locked.values.map(&:entryable_id)).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
      locked.each_value { |entry| entry.association(:entryable).target = transactions[entry.entryable_id] }
      pending = locked[id]
      return [] unless eligible?(pending, identities, pending: true)
      unless candidate_ids(account, pending) == captured
        raise Fence::OwnershipChanged, "SimpleFIN cleanup candidates changed before publication"
      end

      exact = captured[:exact].one? && captured[:reverse] == [ id ] ? locked[captured[:exact].first] : nil
      if eligible?(exact, identities, pending: false)
        pending.update!(excluded: true)
        return [ outcome(:exact, account, pending, exact) ]
      end
      outcomes = []
      # A truncated candidate set cannot establish uniqueness, even for a hint.
      if captured[:fuzzy].size <= CANDIDATE_LIMIT && pending.transaction.extra["potential_posted_match"].blank?
        words = match_words(pending.name)
        fuzzy = captured[:fuzzy].filter_map { |candidate_id| locked[candidate_id] }
          .select { |candidate| words.present? && match_words(candidate.name) == words }
        if fuzzy.one? && eligible?(fuzzy.first, identities, pending: false)
          match = fuzzy.first
          pending.transaction.update!(extra: pending.transaction.extra.merge("potential_posted_match" => {
            "entry_id" => match.id, "reason" => "fuzzy_amount_match", "posted_amount" => match.amount.to_s,
            "confidence" => "medium", "dismissed" => false, "detected_at" => observed_on.to_s
          }))
          outcomes << outcome(:fuzzy_suggestion, account, pending, match)
        end
      end
      if pending.date < observed_on - 8
        pending.update!(excluded: true)
        outcomes << outcome(:stale, account, pending)
      end
      outcomes
    end

    def eligible?(entry, identities, pending:)
      return false unless entry&.transaction? && entry.transaction && entry.source == SOURCE && entry.external_id.present?
      return false if entry.protected_from_sync? || entry.reconciled? || entry.locked_attributes.present? || entry.transaction.locked_attributes.present?
      return false if entry.parent_entry_id || entry.child_entries.exists? || entry.transaction.transfer_id || entry.transaction.transfer?
      return false if Transfer.where(inflow_transaction_id: entry.entryable_id).or(Transfer.where(outflow_transaction_id: entry.entryable_id)).exists?
      return false if Entry.where(entryable_type: "Transaction", entryable_id: entry.entryable_id).where.not(id: entry.id).exists?
      return false if EntrySource.where(entry_id: entry.id).or(EntrySource.where(entry_identity: entry.id)).exists?
      value = identities[entry.external_id]
      return false unless value && value.slice(:external_id, :amount, :currency, :date, :name) == {
        external_id: entry.external_id, amount: entry.amount, currency: entry.currency, date: entry.date, name: entry.name
      } && value[:pending] == pending
      extra = entry.transaction.extra
      return false unless extra.is_a?(Hash) && extra[SOURCE].is_a?(Hash)
      return false if (Transaction::PENDING_PROVIDERS - [ SOURCE ]).any? { |key| extra.key?(key) }
      ActiveModel::Type::Boolean.new.cast(extra.dig(SOURCE, "pending")) == pending
    end

    def match_words(name)
      name.to_s.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
    end

    def outcome(kind, account, pending, posted = nil)
      { kind: kind, account_id: account.id, account_name: account.name, entry_id: pending.id,
        pending_name: pending.name, posted_name: posted&.name }
    end
end
