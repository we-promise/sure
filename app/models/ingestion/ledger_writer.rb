# Called inside a fenced batch transaction. Existing accounting rules remain in
# ProviderImportAdapter; this boundary owns source selection and durable evidence.
class Ingestion::LedgerWriter
  def initialize(external_account:, batch:, securities: {})
    @external_account = external_account
    @batch = batch
    @account = external_account.current_account
    @securities = securities
  end

  def apply(page, observed_pending_ids: [], allow_absence: true)
    raise Provider::AccountData::InvalidResponse, "Source account is not linked" unless account
    unless batch.origin_kind == "provider" && batch.external_account_id == external_account.id &&
        batch.provider_connection_id == external_account.provider_connection_id && batch.family_id == external_account.family_id
      raise Provider::AccountData::InvalidResponse, "Ledger batch belongs to another source account"
    end
    resolver = Provider::AccountData::GenerationAccounts.new(external_account.provider_connection, resource: batch.stream,
      identity_namespace: external_account.identity_namespace)
    expected = batch.source_binding
    unless expected.is_a?(Hash) && expected.present?
      raise Provider::AccountData::StaleWriter, "Ledger publication requires the original captured source binding"
    end
    unless expected["account_id"] == account&.id && expected["publication"] == "ledger"
      raise Provider::AccountData::StaleWriter, "Financial account changed after source capture"
    end
    resolver.with_verified_binding(external_account, expected) do |fresh|
      @external_account, @account = fresh, fresh.current_account
      apply_records(page, observed_pending_ids: observed_pending_ids, allow_absence: allow_absence)
    end
  end

  private

    def apply_records(page, observed_pending_ids:, allow_absence:)
      if batch.provider_sync_generation && !batch.provider_sync_generation.sealed?
        raise Provider::AccountData::InvalidResponse, "Transaction generation has not sealed its complete change set"
      end
      raise Provider::AccountData::InvalidResponse, "Source account is not linked" unless account
      account.with_lock do
        policy = Account::SourcePolicy.active.find_by!(account: account, resource: batch.stream)
        unless batch.source_policy_version == policy.id
          raise Provider::AccountData::StaleWriter, "Source selection changed during ingestion"
        end
        if Account::SourcePolicy::CASH_RESOURCES.include?(batch.stream) &&
            Account::SourcePolicy.active.where(account: account, resource: Account::SourcePolicy::CASH_RESOURCES).distinct.count(:account_provider_id) > 1
          raise Provider::AccountData::StaleWriter, "Transaction and activity feeds disagree on cash movement authority"
        end
        authoritative = policy.account_provider_id == external_account.account_provider.id
        case batch.stream
        when "transactions"
          if page.removed_ids.any? && (!page.complete? || page.coverage.with_indifferent_access[:removal_policy] != "exact_external_id" ||
              (page.records.map { |record| record[:external_id] } & page.removed_ids).any?)
            raise Provider::AccountData::InvalidResponse, "Transaction removals need a complete unambiguous change set"
          end
          page.records.each do |record|
            identity = import_transaction(record, authoritative: authoritative)
            observed_pending_ids << identity if record[:pending] && identity
          end
          Ingestion::TransactionWithdrawals.new(external_account: external_account, batch: batch, source: source)
            .apply(page.removed_ids, authoritative: authoritative) if page.removed_ids.any?
          prune_pending(page, observed_pending_ids) if authoritative && allow_absence
        when "balances"
          import_balance(page) if authoritative
        when "holdings"
          page.records.each { |record| import_holding(record, authoritative: authoritative) }
        when "activities"
          excluded = authoritative ? Ingestion::ActivityGroups.new(page: page, account: account, source: source).insertion_exclusions : []
          page.records.each { |record| import_activity(record, authoritative: authoritative && !excluded.include?(record[:external_id])) }
        else
          raise Provider::AccountData::UnsupportedCapability, "No ledger writer for this resource"
        end
      end
    end

    attr_reader :external_account, :batch, :account, :securities

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def source
      @source ||= Provider::AccountData::Registry.fetch(external_account.provider_key).definition.source
    end

    def import_transaction(record, authoritative:)
      unless %w[transaction activity].include?(record.kind)
        raise Provider::AccountData::InvalidResponse, "Expected a cash movement"
      end
      pending = record.kind == "transaction" && record[:pending]
      metadata = (record[:metadata] || {}).with_indifferent_access
      identity = transaction_identity(record, metadata, authoritative: authoritative)
      observation = SourceRecord.find_or_initialize_by(
        external_account: external_account, kind: record.kind, external_id: identity
      )
      incoming_order = metadata.fetch(:observation_order, [])
      unless incoming_order.is_a?(Array) && incoming_order.all? { |value| value.is_a?(Integer) }
        raise Provider::AccountData::InvalidResponse, "Invalid observation order"
      end
      if observation.persisted? && observation.observation_order.any?
        unless incoming_order.size == observation.observation_order.size
          raise Provider::AccountData::InvalidResponse, "Observation ordering contract changed"
        end
        return identity if (incoming_order <=> observation.observation_order) == -1
      end
      if authoritative && external_account.provider_key == "lunchflow" && record.kind == "transaction"
        @lunchflow_posted_match ||= Provider::AccountData::Lunchflow::PostedMatch.new(external_account: external_account, account: account, batch: batch)
        return identity if @lunchflow_posted_match.apply(record: record, observation: observation)
      end
      resolution = resolve_cash_identity(observation, record, identity) if authoritative
      return nil if resolution&.retired_alias?
      resolved = resolution if resolution && (resolution.resolved? || resolution.pending_transition?)
      existing = resolved&.entry || existing_financial_entry(identity) if authoritative
      lock_financial_entry(existing)
      if existing && !existing.transaction?
        raise Provider::AccountData::InvalidResponse, "Cash movement identity has a different financial type"
      end
      if stale_pending_observation?(record, metadata, observation, resolved)
        # The original page remains immutable batch evidence. Do not replace the
        # booked observation's publication pointer with this stale pending input.
        return identity
      end
      observation.assign_attributes(family: account.family, account: account, ingestion_batch: batch, withdrawn: false, pending: pending)
      observation.observation_order = incoming_order
      if observation.new_record?
        observation.input_external_id = record[:external_id]
        observation.input_occurrence = metadata.fetch(:identity_occurrence, 0)
      end
      observation.save!
      return identity unless authoritative

      extra = (metadata[:extra] || {}).deep_stringify_keys
      extra[source] ||= {}
      extra[source]["pending"] = pending if record.kind == "transaction" && metadata[:pending_provided] != false
      extra["security_id"] = securities.fetch([ record.kind, record[:external_id] ]).id if record.kind == "activity" && record[:security]
      entry = existing if metadata[:update_policy] == "insert_only" && !resolved&.pending_transition?
      unless entry
        protected_entry = existing && (existing.protected_from_sync? || existing.reconciled?)
        merchant = resolve_merchant(metadata[:merchant]) unless protected_entry
        entry = import_adapter.import_transaction(
          external_id: identity, amount: record[:amount], currency: record[:currency],
          date: record[:date], name: record[:name], source: source,
          pending_transaction_id: resolved&.pending_transition? ? resolved.previous_external_id : record[:pending_external_id], extra: extra,
          notes: metadata[:notes], kind: metadata[:kind], merchant: merchant,
          category_id: protected_entry ? nil : category_id(metadata), investment_activity_label: activity_label(record, metadata),
          resolved_entry: resolved, native_identity: true
        )
      end
      return identity unless entry
      mapping = observation.entry_source
      if mapping && mapping.entry_id != entry.id
        raise Provider::AccountData::InvalidResponse, "Source record changed financial identity"
      end
      observation.create_entry_source!(
        entry: entry, account: account, family: account.family,
        role: "posting", match_method: "provider_reconciliation"
      ) unless mapping
      if resolved&.pending_transition?
        SourceRecord.find_by!(id: resolved.source_record_id, external_account: external_account, account: account)
          .update!(ingestion_batch: batch, pending: false, withdrawn: true)
      end
      identity
    end

    def stale_pending_observation?(record, metadata, observation, resolved)
      return false unless record.kind == "transaction"
      adapter = (@transaction_status_adapter ||= Provider::AccountData::Registry.fetch(external_account.provider_key))
      policy = adapter.transaction_status_policy
      captured = metadata[:transaction_status_policy]
      return false if policy.nil? && captured.nil?
      unless policy == "pending_to_posted" && captured == policy
        raise Provider::AccountData::InvalidResponse, "Transaction status policy differs from its captured contract"
      end
      return false unless record[:pending] && observation.persisted? && !observation.pending?

      # Secondary feeds still own their observation history. Letting one replace
      # booked evidence with pending would regress the posting when selected
      # again. Resolve its proof without granting it financial write authority.
      resolved ||= identity_resolver.resolve(source_record: observation, kind: record.kind,
        external_id: observation.external_id, entryable_type: "Transaction")
      if resolved.unmapped?
        if existing_financial_entry(observation.external_id)
          raise Ingestion::MappedEntryResolver::Conflict, "Booked observation requires proof for its existing financial identity"
        end
        return true
      end
      unless resolved.resolved?
        raise Ingestion::MappedEntryResolver::Conflict, "Booked observation requires a current mapped identity"
      end
      lock_financial_entry(resolved.entry)

      # The skip must repeat the same locked proof check as a financial import;
      # a stale status is not permission to accept a changed or detached mapping.
      Ingestion::MappedEntryResolver.for_import!(resolved, account: account,
        external_id: resolved.external_id, source: source, entryable_type: "Transaction")
      true
    end

    def import_activity(record, authoritative:)
      raise Provider::AccountData::InvalidResponse, "Expected an investment activity" unless record.kind == "activity"
      unless %w[buy sell dividend contribution withdrawal interest fee transfer other reinvestment].include?(record[:activity_type])
        raise Provider::AccountData::UnsupportedCapability, "Unsupported investment activity"
      end
      return import_transaction(record, authoritative: authoritative) unless record.ledger_type == "trade"

      identity = record[:external_id]
      if authoritative && external_account.provider_key == "coinbase"
        @coinbase_trade_identity ||= Provider::AccountData::Coinbase::LegacyTradeIdentity.new(external_account: external_account, account: account, batch: batch)
        identity = @coinbase_trade_identity.resolve(record)
      end
      observation = SourceRecord.find_or_initialize_by(external_account: external_account, kind: "activity", external_id: identity)
      resolution = identity_resolver.resolve(source_record: observation, kind: "activity", external_id: identity, entryable_type: "Trade") if authoritative && observation.persisted?
      resolved = resolution if resolution&.resolved?
      entry = resolved&.entry || existing_financial_entry(identity) if authoritative
      lock_financial_entry(entry)
      if entry && !entry.trade?
        raise Provider::AccountData::InvalidResponse, "Activity identity has a different financial type"
      end
      observation.assign_attributes(family: account.family, account: account, ingestion_batch: batch, withdrawn: false)
      observation.save!
      return unless authoritative

      metadata = (record[:metadata] || {}).with_indifferent_access
      if !metadata[:fee].nil? && !(metadata[:fee].is_a?(BigDecimal) && metadata[:fee].finite?)
        raise Provider::AccountData::InvalidResponse, "Trade fee must be an exact decimal"
      end
      extra = metadata[:extra]
      unless extra.nil? || (extra.is_a?(Hash) && (extra.keys.map(&:to_s) - [ source ]).empty? && extra.values.all? { |value| value.is_a?(Hash) })
        raise Provider::AccountData::InvalidResponse, "Trade metadata must stay in its provider namespace"
      end
      if entry && metadata[:update_policy] == "insert_only"
        if metadata[:repair_activity_label] == true && !entry.protected_from_sync? && !entry.reconciled? &&
            !entry.trade.locked?(:investment_activity_label) && entry.trade.investment_activity_label.blank?
          entry.trade.update!(investment_activity_label: activity_label(record, metadata))
        end
      elsif !(entry && (entry.protected_from_sync? || entry.reconciled?))
        quantity, price = record[:quantity], record[:price]
        valid_quantity = if quantity.nil?
          false
        elsif quantity.zero?
          metadata[:allow_zero_quantity] == true
        elsif record[:activity_type] == "buy"
          quantity.positive?
        elsif record[:activity_type] == "sell"
          quantity.negative?
        else
          true
        end
        unless valid_quantity && price
          raise Provider::AccountData::InvalidResponse, "Trade quantity or price is incomplete"
        end
        entry = import_adapter.import_trade(
          security: securities.fetch([ record.kind, record[:external_id] ]),
          quantity: quantity, price: price, amount: record[:amount], currency: record[:currency],
          date: record[:date], name: record[:name], external_id: identity, source: source,
          activity_label: activity_label(record, metadata), exchange_rate: metadata[:exchange_rate], notes: metadata[:notes], fee: metadata[:fee], extra: extra,
          resolved_entry: resolved, native_identity: true
        )
      end
      mapping = observation.entry_source
      if mapping && mapping.entry_id != entry.id
        raise Provider::AccountData::InvalidResponse, "Activity changed financial identity"
      end
      observation.create_entry_source!(entry: entry, account: account, family: account.family,
        role: "posting", match_method: "provider_reconciliation") unless mapping
    end

    def activity_label(record, metadata)
      metadata[:investment_activity_label] || (record.kind == "activity" ? record[:activity_type].capitalize : nil)
    end

    def identity_resolver
      @identity_resolver ||= Ingestion::MappedEntryResolver.new(external_account: external_account, account: account,
        definition: Provider::AccountData::Registry.fetch(external_account.provider_key).definition)
    end

    def existing_financial_entry(identity)
      entry = account.entries.find_by(source: source, external_id: identity)
      if source == "plaid" && account.entries.where(plaid_id: identity).where.not(id: entry&.id).exists?
        raise Ingestion::MappedEntryResolver::Conflict, "Legacy Plaid identity requires reviewed financial evidence"
      end
      entry
    end

    def lock_financial_entry(entry)
      return unless entry
      entry.lock!
      entry.entryable&.lock!
    end

    def resolve_cash_identity(observation, record, identity)
      result = identity_resolver.resolve(source_record: observation, kind: record.kind, external_id: identity, entryable_type: "Transaction") if observation.persisted?
      return result if result && !result.unmapped?
      return result unless record.kind == "transaction" && !record[:pending]
      return result if account.entries.exists?(source: source, external_id: identity)

      if record[:pending_external_id].blank?
        @pending_transaction_match ||= Ingestion::PendingTransactionMatch.new(external_account: external_account, account: account, batch: batch)
        return @pending_transaction_match.resolve(record: record, posted_external_id: identity) || result
      end
      return result if record[:pending_external_id] == identity

      previous = SourceRecord.find_by(external_account: external_account, kind: "transaction", external_id: record[:pending_external_id])
      if previous
        identity_resolver.resolve_pending_transition(source_record: previous, pending_external_id: record[:pending_external_id], posted_external_id: identity)
      elsif account.entries.exists?(source: source, external_id: record[:pending_external_id]) ||
          (source == "plaid" && account.entries.exists?(plaid_id: record[:pending_external_id]))
        raise Ingestion::MappedEntryResolver::Conflict, "Pending transition requires reviewed financial evidence"
      end
    end

    def transaction_identity(record, metadata, authoritative:)
      return record[:external_id] unless authoritative && metadata[:identity_policy] == "reuse_pending_or_allocate_suffix"

      if source == "akahu"
        @akahu_pending_identity ||= Provider::AccountData::Akahu::PendingIdentity.new(external_account: external_account, account: account)
        retained = @akahu_pending_identity.resolve(record: record)
        return retained if retained
      end

      # Persist the initial legacy collision resolution. Later refreshes of the
      # same observation must not allocate another suffix after it becomes posted.
      recorded = SourceRecord.where(
        external_account: external_account, kind: "transaction", input_external_id: record[:external_id],
        input_occurrence: metadata.fetch(:identity_occurrence, 0), withdrawn: false
      ).order(created_at: :desc).first
      return recorded.external_id if recorded

      base = record[:external_id]
      identity = base
      suffix = 0
      loop do
        existing = account.entries.find_by(source: source, external_id: identity)
        assigned = SourceRecord.find_by(external_account: external_account, kind: "transaction", external_id: identity)
        another_occurrence = assigned && (assigned.input_external_id != record[:external_id] || assigned.input_occurrence != metadata.fetch(:identity_occurrence, 0))
        unless another_occurrence
          return identity if existing.nil? || (existing.entryable.is_a?(Transaction) && existing.transaction.pending?)
        end
        suffix += 1
        identity = "#{base}_#{suffix}"
      end
    end

    def import_holding(record, authoritative:)
      raise Provider::AccountData::InvalidResponse, "Expected a holding" unless record.kind == "holding"
      observation = SourceRecord.find_or_initialize_by(external_account: external_account, kind: "holding", external_id: record[:external_id])
      observation.assign_attributes(family: account.family, account: account, ingestion_batch: batch, withdrawn: false)
      observation.save!
      return unless authoritative

      metadata = (record[:metadata] || {}).with_indifferent_access
      if metadata[:delete_future_holdings]
        raise Provider::AccountData::UnsupportedCapability, "Historical holding replacement needs a completed-snapshot policy"
      end
      security = securities.fetch([ record.kind, record[:external_id] ])
      ledger_external_id = metadata[:holding_identity] == "security_date_currency" ? nil : record[:external_id]
      existing = if ledger_external_id
        account.holdings.find_by(external_id: ledger_external_id)
      else
        account.holdings.find_by(security: security, date: record[:date], currency: record[:currency])
      end
      if existing&.account_provider_id && existing.account_provider_id != external_account.account_provider.id
        raise Provider::AccountData::InvalidResponse, "Position identity belongs to another source"
      end
      composite = account.holdings.find_by(security: security, date: record[:date], currency: record[:currency])
      if composite&.account_provider_id && composite.account_provider_id != external_account.account_provider.id
        raise Provider::AccountData::InvalidResponse, "Overlapping source positions require handover reconciliation"
      end
      if composite&.external_id.present? && composite.external_id != ledger_external_id
        raise Provider::AccountData::InvalidResponse, "Position components need explicit aggregation or identity reconciliation"
      end
      price = record[:price]
      amount = record[:amount] || (price && record[:quantity] * price)
      unless price && amount
        raise Provider::AccountData::InvalidResponse, "Holding valuation is incomplete"
      end
      holding = import_adapter.import_holding(
        security: security, external_id: ledger_external_id, source: source,
        quantity: record[:quantity], amount: amount, price: price, currency: record[:currency], date: record[:date],
        cost_basis: metadata[:cost_basis], account_provider_id: external_account.account_provider.id,
        delete_future_holdings: false, strict_identity: true
      )
      mapping = observation.holding_source
      if mapping && mapping.holding_id != holding.id
        raise Provider::AccountData::InvalidResponse, "Source position changed financial identity"
      end
      observation.create_holding_source!(holding: holding, account: account, family: account.family,
        role: holding.account_provider_id == external_account.account_provider.id ? "posting" : "evidence") unless mapping
    end

    def resolve_merchant(details)
      return unless details
      values = details.with_indifferent_access
      import_adapter.find_or_create_merchant(
        provider_merchant_id: values.fetch(:external_id), name: values.fetch(:name), source: source,
        website_url: values[:website_url], logo_url: values[:logo_url]
      )
    rescue ActiveRecord::RecordInvalid
      nil
    end

    def category_id(metadata)
      if metadata[:category_bootstrap] == "empty_family" && !@category_bootstrap_checked
        # Legacy Plaid initializes defaults when it processes its first selected
        # row, even if auto-matching is disabled. Secondary evidence and empty
        # pages never reach this financial-write boundary.
        account.family.categories.bootstrap! if account.family.categories.none?
        @category_bootstrap_checked = true
        @candidate_matcher = nil
      end
      return unless account.enable_category_matcher?
      if metadata[:category_candidates]
        @candidate_matcher ||= Ingestion::CategoryMatcher.new(account.family.categories.to_a, locale: account.family.locale)
        return @candidate_matcher.match(metadata[:category_candidates])&.id
      end
      slug = metadata[:category_slug]
      return unless slug.present?
      case external_account.provider_key
      when "up"
        @category_matcher ||= UpAccount::Transactions::CategoryMatcher.new(account.family.categories.to_a)
        @category_matcher.match(slug)&.id
      end
    end

    def import_balance(page)
      # A paginated portfolio or delayed statement can make durable progress
      # before it has a complete monetary observation. The source-policy check
      # still runs, but no cached amount or currency is changed by that prefix.
      return if page.records.empty? && !page.complete?
      unless page.records.one? && page.records.first.kind == "account"
        raise Provider::AccountData::InvalidResponse, "Expected one account balance"
      end
      record = page.records.first
      metadata = (record[:metadata] || {}).with_indifferent_access
      Ingestion::AccountEnrichment.new(account: account, source: source).apply!(metadata: metadata)
      policy = (metadata[:balance_policy] || {}).with_indifferent_access
      balance = record[:balance]
      balance = record[:available_balance] if balance.nil? && policy[:observed_balance] == "current_else_available"
      return if balance.nil?
      if Array(policy[:debt_types]).include?(account.accountable_type)
        balance = case policy[:debt_transform]
        when "absolute" then balance.abs
        when "negate" then -balance
        when "preserve", nil then balance
        else raise Provider::AccountData::InvalidResponse, "Unknown debt balance convention"
        end
      end
      if account.accountable_type == "CreditCard"
        balance = simplefin_credit_balance(page, record, balance) if policy[:credit_card] == "simplefin_overpayment_v1"
        balance = interpret_credit_card_balance(balance, policy, currency: record[:currency]) if policy[:credit_card_mode]
      end
      if balance.nil?
        return
      end
      cash_balance = policy[:cash_balance] == "balance" ? balance : record[:cash_balance]
      cash_balance = BigDecimal("0") if policy[:investment_cash_zero] && account.accountable_type == "Investment"
      cash_balance = record[:cash_balance] if policy[:investment_cash] == "record" && account.accountable_type == "Investment"
      account.update!(currency: record[:currency])
      if policy[:current_anchor]
        observed_date = balance_anchor_date(record, policy)
        result = Account::CurrentBalanceManager.new(account, date: observed_date).set_current_balance(balance)
        raise Provider::AccountData::InvalidResponse, "Could not apply the captured balance anchor" unless result.success?
        account.update!(cash_balance: cash_balance || balance)
      else
        import_adapter.update_balance(balance: balance, cash_balance: cash_balance, source: source)
      end
      if account.accountable_type == "CreditCard" && !record[:available_balance].nil?
        if policy[:available_credit] == "available_balance" || (policy[:available_credit] == "positive_available_balance" && record[:available_balance].positive?)
          account.credit_card.update!(available_credit: record[:available_balance])
        end
      end
    end

    def balance_anchor_date(record, policy)
      captured_date = batch.sync.created_at.in_time_zone(account.family.timezone).to_date
      case policy[:anchor_date]
      when nil, "sync_date" then captured_date
      when "balance_date"
        value = record[:balance_date]
        unless value.instance_of?(Date) && value <= captured_date
          raise Provider::AccountData::InvalidResponse, "Balance anchor requires its captured observation date"
        end
        value
      else
        raise Provider::AccountData::InvalidResponse, "Unknown balance anchor date policy"
      end
    end

    def interpret_credit_card_balance(balance, policy, currency:)
      unless policy[:credit_limit].nil? || [ String, Integer, BigDecimal ].any? { |type| policy[:credit_limit].is_a?(type) }
        raise Provider::AccountData::InvalidResponse, "Credit limits require exact decimal values"
      end
      limit = policy[:credit_limit] && BigDecimal(policy[:credit_limit].to_s)
      raise Provider::AccountData::InvalidResponse, "Invalid credit limit" if limit && !limit.finite?
      limit = nil unless limit&.positive?
      credit = account.credit_card.available_credit if account.currency == currency
      case policy[:credit_card_mode]
      when "available_credit"
        return nil if account.currency != currency && limit.nil?
        limit ||= credit if credit&.positive?
        account.credit_card.update!(available_credit: limit)
        return nil unless limit
        [ limit - balance, BigDecimal("0") ].max
      when "outstanding_debt"
        account.credit_card.update!(available_credit: limit ? [ limit - balance, BigDecimal("0") ].max : credit)
        balance
      else
        raise Provider::AccountData::InvalidResponse, "Unknown credit card balance policy"
      end
    end

    def simplefin_credit_balance(page, record, observed)
      snapshot = page.evidence.fetch("balance_policy").with_indifferent_access
      unless snapshot[:account_id] == account.id && snapshot[:family_id] == account.family_id &&
          snapshot[:external_account_id] == external_account.id && snapshot[:account_type] == account.accountable_type
        raise Provider::AccountData::InvalidResponse, "Balance evidence belongs to another account"
      end
      result = Ingestion::BalancePolicies::Simplefin.new(snapshot: snapshot).call(observed_balance: observed)
      if %i[credit debt].include?(result.classification) && result.reason != "sticky_hint"
        expires_at = Time.iso8601(snapshot.fetch(:as_of)) + snapshot.fetch(:settings).fetch(:sticky_days).days
        details = external_account.sensitive_details.deep_merge("balance_policy_state" => {
          "simplefin" => { "value" => result.classification.to_s, "expires_at" => expires_at.iso8601 }
        })
        external_account.update!(sensitive_details: details)
      elsif result.reason == "sticky_hint" && %w[legacy_cache retained_migration].include?(snapshot[:sticky_hint_source])
        external_account.update!(sensitive_details: external_account.sensitive_details.deep_merge(
          "balance_policy_state" => { "simplefin" => snapshot.fetch(:sticky_hint).to_h }
        ))
      end
      case result.classification
      when :credit then -observed.abs
      when :debt then observed.abs
      else
        current = record[:balance] || BigDecimal("0")
        available = record[:available_balance] || BigDecimal("0")
        return -observed.abs if current.positive? && available.positive?
        return observed.abs if current.negative? && available.negative?
        -observed
      end
    end

    def prune_pending(page, observed_ids)
      return unless page.complete? && page.mode == "snapshot"
      coverage = page.coverage.with_indifferent_access
      return if coverage[:pending_absence_authoritative] == false
      observations = SourceRecord.where(external_account: external_account, account: account,
        kind: "transaction", pending: true, withdrawn: false)
      observations = observations.where.not(external_id: observed_ids) if observed_ids.any?
      pending = account.entries.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where("transactions.extra -> ? ->> 'pending' = 'true'", source)
        .where(id: observations.joins(:entry_source).where(entry_sources: { role: "posting" }).select("entry_sources.entry_id"))
      unless coverage[:pending_scope] == "all"
        return unless coverage[:start] && coverage[:end]
        # Inclusive timestamp filters can straddle local calendar days. Only prune
        # interior dates whose absence this exact request actually establishes.
        first_date = Time.iso8601(coverage[:start]).in_time_zone(account.family.timezone).to_date + 1
        last_date = Time.iso8601(coverage[:end]).in_time_zone(account.family.timezone).to_date - 1
        return if first_date > last_date
        pending = pending.where(date: first_date..last_date)
      end
      pending.find_each do |entry|
        entry.lock!
        entry.entryable&.lock!
        # User edits or another observation may have changed this row since the
        # candidate query. Re-evaluate membership after locking both records.
        next unless pending.where(id: entry.id).exists?
        ids = observations.joins(:entry_source).where(entry_sources: { role: "posting", entry_id: entry.id }).pluck(:external_id)
        Ingestion::TransactionWithdrawals.new(external_account: external_account, batch: batch, source: source)
          .apply(ids, authoritative: true)
      end
    end
end
