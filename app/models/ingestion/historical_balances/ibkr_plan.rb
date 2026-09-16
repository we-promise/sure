class Ingestion::HistoricalBalances::IbkrPlan
  def initialize(external_account:, source_batch:, rate_resolver: Provider::AccountData::ExchangeRateResolver.new, capture_revision: nil, trade_flow_snapshot: nil)
    @external_account, @source_batch, @rate_resolver = external_account, source_batch, rate_resolver
    @capture_revision = capture_revision || source_batch.id
    if trade_flow_snapshot && !trade_flow_snapshot.is_a?(Ingestion::HistoricalBalances::TradeFlowSnapshot)
      raise ArgumentError, "Expected captured historical trade flows"
    end
    @trade_flow_snapshot = trade_flow_snapshot
    unless @capture_revision.is_a?(String) && @capture_revision.match?(/\A[A-Za-z0-9-]{1,64}\z/)
      raise ArgumentError, "Historical capture revision must be a stable execution identifier"
    end
  end

  def prepare(phase:)
    raise ArgumentError unless %w[opening_anchor equity_history].include?(phase)
    @external_account.reload
    account = @external_account.current_account&.reload
    connection = @external_account.provider_connection.reload
    control = connection.provider_migration_control
    unless connection.good? && !connection.scheduled_for_deletion && (control.nil? || control.native_owned?)
      raise Provider::AccountData::StaleWriter, "IBKR does not own this connection"
    end
    unless account && account.family_id == connection.family_id && @external_account.family_id == connection.family_id &&
        @external_account.provider_key == "ibkr" && connection.provider_key == "ibkr" && @source_batch.provider_connection_id == connection.id &&
        @source_batch.external_account_id == @external_account.id && @source_batch.family_id == account.family_id &&
        @source_batch.origin_kind == "provider" && @source_batch.stream == "equity_snapshots" && @source_batch.mode == "snapshot" && @source_batch.complete? &&
        @source_batch.scope_key == "account:#{@external_account.id}" && %w[captured applied].include?(@source_batch.status)
      raise Provider::AccountData::InvalidResponse, "IBKR equity snapshot ownership does not match this account"
    end
    snapshot = Provider::AccountData::Ibkr::EquitySnapshot.load(@source_batch.payload)
    unless snapshot[:external_id] == @external_account.external_id && snapshot[:currency] == account.currency
      raise Provider::AccountData::InvalidResponse, "IBKR equity snapshot identity or base currency changed"
    end
    policy = Account::SourcePolicy.active.find_by!(account: account, resource: "historical_balances")
    link = @external_account.account_provider
    unless policy.account_provider_id == link&.id && @source_batch.source_policy_version == policy.id
      raise Provider::AccountData::StaleWriter, "IBKR no longer owns historical balances"
    end
    artifact = snapshot[:source_artifact]
    if artifact && (artifact["account_provider_id"] != link.id || artifact["account_provider_revision"] != link.lock_version)
      raise Provider::AccountData::StaleWriter, "IBKR equity snapshot account binding changed"
    end
    Provider::AccountData::Ibkr::EquityHandoff.assert_source_current!(account: account,
      external_account: @external_account, source_batch: @source_batch)
    inputs = Ingestion::HistoricalBalances::Inputs.capture(account)
    balance_policy = Account::SourcePolicy.active.find_by(account: account, resource: "balances")
    anchor = opening_anchor(inputs, imported_balance: snapshot[:imported_current_balance]) if balance_policy&.account_provider_id == link.id
    if phase == "equity_history" && anchor
      raise Provider::AccountData::InvalidResponse, "Repair the default opening anchor before materializing history"
    end
    protected_dates = protected_dates(inputs)
    fx = if phase != "equity_history"
      { flows: {}, failed_dates: [], evidence: [] }
    elsif @trade_flow_snapshot
      @trade_flow_snapshot.resolve(inputs: inputs, currency: snapshot[:currency])
    else
      Ingestion::HistoricalBalances::TradeFlows.new(inputs: inputs, currency: snapshot[:currency], rate_resolver: @rate_resolver).capture
    end
    rows = if phase == "equity_history"
      base_balances = inputs.fetch("balances").select { |row| row.fetch("currency") == snapshot[:currency] }
      balances = base_balances.to_h do |row|
        [ row.fetch("date"), { cash_balance: row["cash_balance"] } ]
      end
      # Both kinds of skipped date retain their persisted total. That value must
      # also seed the next day's performance, not the unapplied provider total.
      retained_dates = (protected_dates + fx.fetch(:failed_dates)).uniq
      retained = base_balances.select { |row| retained_dates.include?(row.fetch("date")) }
        .to_h { |row| [ row.fetch("date"), row.fetch("end_balance") || row.fetch("balance") ] }
      unless protected_dates.select { |date| date <= snapshot[:observed_on] }.all? { |date| retained.key?(date) }
        raise Provider::AccountData::IncompletePage, "Protected valuation dates must be materialized before historical overrides"
      end
      Provider::AccountData::Ibkr::HistoricalBalances.project(equity_rows: snapshot[:equity_rows], currency: snapshot[:currency],
        existing_balances: balances, trade_flows: fx.fetch(:flows), failed_fx_dates: fx.fetch(:failed_dates),
        retained_totals: retained,
        anchor_date: current_anchor_date(inputs), observed_on: snapshot[:observed_on]).reject { |row| protected_dates.include?(row.fetch(:date)) }
    else
      []
    end
    Ingestion::HistoricalBalances::Command.new(
      "account_id" => account.id, "family_id" => account.family_id, "external_account_id" => @external_account.id,
      "provider_connection_id" => connection.id, "account_provider_id" => link.id, "source_batch_id" => @source_batch.id,
      "account_provider_revision" => link.lock_version,
      "source_policy_version" => policy.id, "writer_epoch" => @source_batch.writer_epoch, "phase" => phase, "capture_revision" => @capture_revision,
      "observed_on" => snapshot[:observed_on], "source_sha256" => Ingestion::HistoricalBalances.fingerprint(@source_batch.payload),
      "inputs" => inputs, "inputs_sha256" => Ingestion::HistoricalBalances.fingerprint(inputs), "rows" => rows,
      "opening_anchor" => phase == "opening_anchor" ? anchor : nil,
      "balance_policy_version" => balance_policy&.id,
      "anchor_policy_version" => phase == "opening_anchor" && anchor ? balance_policy.id : nil,
      "fx_evidence" => fx.fetch(:evidence), "failed_fx_dates" => fx.fetch(:failed_dates), "protected_dates" => protected_dates)
  end

  # Capture is separate from application, so a worker can retry the exact command
  # after a crash. A changed input state requires a new capture, never mutation.
  def capture!(phase:)
    raise ArgumentError unless %w[opening_anchor equity_history].include?(phase)
    @external_account.reload
    account = @external_account.current_account&.reload
    raise Provider::AccountData::InvalidResponse, "Historical source is not linked" unless account
    fingerprint = Ingestion::HistoricalBalances.fingerprint(Ingestion::HistoricalBalances::Inputs.capture(account))
    balance_policy = Account::SourcePolicy.active.find_by(account: account, resource: "balances")
    existing = @external_account.provider_connection.ingestion_batches.find_by(idempotency_key: capture_key(phase, fingerprint,
      link_revision: @external_account.account_provider.lock_version, balance_policy_version: balance_policy&.id))
    # Preserve already-captured FX on a retry, even if market data changed since.
    # Application still rechecks captured source authority and financial inputs.
    return indexed_capture(existing) if existing
    command = prepare(phase: phase)
    key = capture_key(phase, command[:inputs_sha256], link_revision: command[:account_provider_revision], balance_policy_version: command[:balance_policy_version])
    batch = @external_account.provider_connection.ingestion_batches.find_or_initialize_by(idempotency_key: key)
    if batch.persisted?
      raise Provider::AccountData::InvalidResponse, "Historical command differs from its saved capture" unless batch.payload == command.payload
      return indexed_capture(batch)
    end
    batch.assign_attributes(family_id: command[:family_id], external_account: @external_account, sync: @source_batch.sync,
      origin_kind: "provider", stream: command.stream, scope_key: "account:#{@external_account.id}", schema_version: 1,
      writer_epoch: command[:writer_epoch], source_policy_version: command[:source_policy_version], mode: "snapshot",
      complete: command[:failed_fx_dates].empty?, coverage: { "end" => command[:observed_on].iso8601,
        "source_batch_id" => @source_batch.id, "failed_fx_dates" => command[:failed_fx_dates].map(&:iso8601), "protected_dates" => command[:protected_dates].map(&:iso8601) },
      payload: command.payload, source_binding: Ingestion::HistoricalBalances::SourceBinding.capture(command: command))
    batch.save!
    batch
  end

  private
    def indexed_capture(batch)
      # The original command owns this projection. Reusing a capture must not
      # infer historical routing from today's financial account or source link.
      Ingestion::HistoricalBalances::SourceBinding.index!(batch: batch)
      batch.reload
      Ingestion::HistoricalBalances::SourceBinding.verify!(batch: batch)
      batch
    end

    def capture_key(phase, fingerprint, link_revision:, balance_policy_version:)
      anchor_revision = phase == "opening_anchor" ? (balance_policy_version || "none") : "unused"
      "historical:#{@source_batch.id}:#{phase}:#{@capture_revision}:#{link_revision}:#{anchor_revision}:#{fingerprint}"
    end

    def opening_anchor(inputs, imported_balance:)
      pairs = valuation_entries(inputs).select { |_entry, valuation| valuation.fetch("kind") == "opening_anchor" }
      raise Provider::AccountData::InvalidResponse, "Ambiguous opening anchor" if pairs.size > 1
      return unless pairs.one?
      entry, valuation = pairs.first
      return if Ingestion::HistoricalBalances::Inputs.protected_valuation?(entry, valuation)
      return unless entry.fetch("currency") == inputs.fetch("account").fetch("currency") && entry.fetch("created_at").to_date == inputs.fetch("account").fetch("created_at").to_date
      return unless entry.fetch("amount") == imported_balance && !entry.fetch("amount").zero?
      other_entries = inputs.fetch("entries").reject { |other| other.fetch("id") == entry.fetch("id") }
      return unless other_entries.any? { |other| other.fetch("entryable_type") != "Valuation" }
      unless other_entries.map { |other| other.fetch("date") }.min > entry.fetch("date")
        raise Provider::AccountData::InvalidResponse, "Default opening anchor date is not before imported history"
      end
      { "entry_id" => entry.fetch("id"), "date" => entry.fetch("date"), "currency" => entry.fetch("currency"),
        "amount" => entry.fetch("amount"), "replacement" => BigDecimal("0") }
    end

    def current_anchor_date(inputs)
      pairs = valuation_entries(inputs).select { |_entry, valuation| valuation.fetch("kind") == "current_anchor" }
      raise Provider::AccountData::InvalidResponse, "Ambiguous current anchor" if pairs.size > 1
      pairs.first&.first&.fetch("date")
    end

    def protected_dates(inputs)
      valuation_entries(inputs).filter_map do |entry, valuation|
        entry.fetch("date") if Ingestion::HistoricalBalances::Inputs.protected_valuation?(entry, valuation)
      end.uniq.sort
    end

    def valuation_entries(inputs)
      valuations = inputs.fetch("valuations").index_by { |valuation| valuation.fetch("id") }
      inputs.fetch("entries").select { |entry| entry.fetch("entryable_type") == "Valuation" }.map do |entry|
        [ entry, valuations.fetch(entry.fetch("entryable_id")) ]
      end
    end
end
