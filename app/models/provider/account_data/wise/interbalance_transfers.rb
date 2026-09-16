# Links provider-proven interbalance postings; it never searches by economics.
# The active StatementBarrier owns admission and locks the full account union.
class Provider::AccountData::Wise::InterbalanceTransfers
  FORMAT = "wise-interbalance/v1"
  MAX_OBSERVATIONS = 2_000
  MAX_BATCH_BYTES = 8.megabytes
  MAX_TOTAL_BYTES = 32.megabytes
  Result = Data.define(:linked, :existing, :skipped)

  # Pure metadata construction. Older/incomplete activity shapes still normalize
  # as before, but cannot authorize a new confirmed transfer.
  def self.proof(raw:, profile_id:, account:, amount:)
    data = raw.with_indifferent_access
    resource = data[:resource].is_a?(Hash) && data[:resource].with_indifferent_access
    id = identifier(data[:id])
    resource_id = resource && identifier(resource[:id])
    title, primary, created = data.values_at(:title, :primaryAmount, :createdOn)
    return unless data[:type] == "INTERBALANCE" && data[:status] == "COMPLETED" && resource &&
      resource[:type] == "BALANCE_TRANSACTION" && id && resource_id &&
      [ title, primary, created ].all? { |value| value.is_a?(String) && value.present? && value.bytesize <= 8192 }
    jar_name = title.scan(/<strong>([^<]+)<\/strong>/).flatten.last.to_s.strip
    currency = primary.scan(/\b[A-Z]{3}\b/).first
    return if jar_name.blank? || jar_name.bytesize > 256 || currency.nil? || currency != account[:currency] || amount.zero?
    jar = account[:account_type] == "SAVINGS" || (account[:metadata] || {}).with_indifferent_access[:balance_type] == "SAVINGS"
    { "format" => FORMAT, "profile_id" => profile_id.to_s, "resource_id" => resource_id, "activity_id" => id,
      "jar_name" => jar_name, "currency" => currency, "account_id" => account[:external_id], "side" => jar ? "jar" : "standard",
      "event_fingerprint" => Digest::SHA256.hexdigest(JSON.generate([ profile_id.to_s, id, resource_id, resource[:type],
        data[:status], title, primary, created ])) }
  end

  def self.identifier(value)
    value = value.to_s if value.is_a?(Integer)
    value if value.is_a?(String) && value.present? && value.bytesize <= 512
  end
  private_class_method :identifier

  def initialize(connection:, sync:, adapter:, barrier:)
    @connection, @sync, @adapter, @barrier = connection, sync, adapter, barrier
    @batches, @bytes = {}, 0
    @linked, @existing, @skipped = 0, 0, Hash.new(0)
  end

  def perform
    unless connection.provider_key == "wise" && sync.syncable_type == "ProviderConnection" && sync.syncable_id == connection.id
      raise Provider::AccountData::StaleWriter, "Wise transfer finalization belongs to another source"
    end
    @barrier.with_verified_inventory do |records, accounts|
      @inventory = records.index_by { |record| record[:metadata].fetch("runtime_external_account_id") }
      @bindings = accounts.transform_values { |value| value.fetch("binding") }
      anchors = observations.joins(:ingestion_batch).where(ingestion_batches: { sync_id: sync.id,
        origin_kind: "provider", status: "applied", stream: "transactions" }).limit(MAX_OBSERVATIONS + 1).to_a
      bounded_rows!(anchors)
      keys = anchors.map { |observation| pair_key!(observation.external_id) }.uniq.sort
      if keys.any?
        rows = observations.where(external_id: keys.flat_map { |key| [ "#{key}_inflow", "#{key}_outflow" ] })
          .order(:id).limit(MAX_OBSERVATIONS + 1).lock("FOR UPDATE NOWAIT").to_a
        bounded_rows!(rows)
        rows.group_by { |observation| pair_key!(observation.external_id) }.sort.each do |key, group|
          link_pair!(key, group)
        end
      end
    end
    result = Result.new(linked: @linked, existing: @existing, skipped: @skipped.to_h.freeze)
    if @skipped.any?
      DebugLogEntry.capture(category: "provider_sync_warning", level: "warn", message: "Wise interbalance pairs require review",
        source: self.class.name, provider_key: "wise", family: connection.family,
        metadata: { provider_connection_id: connection.id, sync_id: sync.id, dispositions: @skipped.to_h })
    end
    result
  rescue ActiveRecord::LockWaitTimeout
    raise Provider::AccountData::IncompletePage, "Wise transfer evidence is being changed; retry finalization", cause: nil
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Wise transfer evidence is invalid", cause: nil
  end

  private
    attr_reader :connection, :sync, :adapter

    def observations
      SourceRecord.where(family_id: connection.family_id, external_account_id: @bindings.keys, kind: "transaction")
        .where("source_records.external_id LIKE ?", "wise\\_interbalance\\_%")
    end

    def pair_key!(identity)
      match = /\A(wise_interbalance_.+)_(inflow|outflow)\z/.match(identity)
      raise Provider::AccountData::StaleWriter, "Wise interbalance identity is malformed" unless match
      match[1]
    end

    def bounded_rows!(rows)
      raise Provider::AccountData::IncompletePage, "Wise transfer evidence exceeds its row bound" if rows.size > MAX_OBSERVATIONS
    end

    def skip(reason)
      @skipped[reason] += 1
    end

    def link_pair!(key, observations)
      return skip("missing_or_ambiguous_legs") unless observations.size == 2 && observations.map(&:external_id).sort == [ "#{key}_inflow", "#{key}_outflow" ]
      return skip("unavailable_posting") if observations.any? { |observation| observation.withdrawn? || observation.pending? || observation.account_id.nil? || !@inventory.key?(observation.external_account_id) }
      legs = observations.map { |observation| captured_leg(observation) }
      return skip("unproved_activity") if legs.any?(&:nil?)
      return skip("no_current_observation") unless legs.any? { |leg| leg[:batch].sync_id == sync.id }
      left, right = legs
      unless left[:proof].except("account_id", "side") == right[:proof].except("account_id", "side") &&
          legs.map { |leg| leg[:proof]["side"] }.sort == %w[jar standard] &&
          legs.map { |leg| leg[:record][:amount] }.sum.zero? &&
          legs.map { |leg| leg[:record][:currency] }.uniq.one? && legs.map { |leg| leg[:record][:date] }.uniq.one?
        return skip("conflicting_activity")
      end
      standard = @inventory.values.select { |account| adapter.standard_statement_account?(account) }
      jars = @inventory.values.reject { |account| adapter.standard_statement_account?(account) }
        .select { |account| account[:name].to_s.strip.casecmp?(left[:proof].fetch("jar_name")) }
      unless standard.one? && jars.one? &&
          [ standard.sole[:external_id], jars.sole[:external_id] ].sort == legs.map { |leg| leg[:proof].fetch("account_id") }.sort
        return skip("ambiguous_profile_routing")
      end
      return skip("source_not_selected") unless legs.all? { |leg| authoritative?(leg) }
      mappings = EntrySource.where(source_record_id: observations.map(&:id), active: true, role: "posting").order(:id).lock("FOR UPDATE NOWAIT").to_a
      return skip("unavailable_posting") unless mappings.size == 2 && mappings.map(&:source_record_id).sort == observations.map(&:id).sort
      entries = Entry.where(id: mappings.map(&:entry_id)).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
      return skip("unavailable_posting") unless entries.size == 2
      transactions = Transaction.where(id: entries.values.map(&:entryable_id)).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
      legs.each do |leg|
        mapping = mappings.find { |value| value.source_record_id == leg[:observation].id }
        entry = entries[mapping.entry_id]
        unless mapping.family_id == connection.family_id && mapping.account_id == leg[:observation].account_id &&
            mapping.entry_identity == entry&.id && entry&.account_id == mapping.account_id && entry.transaction? &&
            entry.source == "wise" && entry.external_id == leg[:record][:external_id] && transactions.key?(entry.entryable_id)
          raise Provider::AccountData::StaleWriter, "Wise transfer posting changed identity"
        end
        leg[:entry], leg[:transaction] = entry, transactions.fetch(entry.entryable_id)
      end
      return skip("same_financial_account") unless legs.map { |leg| leg[:entry].account_id }.uniq.size == 2
      inflow = legs.find { |leg| leg[:record][:amount].negative? }
      outflow = legs.find { |leg| leg[:record][:amount].positive? }
      return skip("conflicting_activity") unless inflow && outflow
      pair = { inflow_transaction_id: inflow[:transaction].id, outflow_transaction_id: outflow[:transaction].id }
      transaction_ids = pair.values
      existing = Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids))
        .order(:id).lock("FOR UPDATE NOWAIT").to_a
      if existing.any?
        # The legacy linker leaves already joined legs alone. In particular,
        # provider evidence must not silently confirm a pending user decision.
        return @existing += 1 if existing.one? && existing.sole.attributes.slice(*pair.keys.map(&:to_s)) == pair.stringify_keys
        return skip("competing_transfer")
      end
      return skip("rejected_transfer") if RejectedTransfer.where(pair).exists?
      return skip("protected_or_changed_posting") if legs.any? { |leg| protected_leg?(leg) }
      Transfer.create!(**pair, status: "confirmed")
      @linked += 1
    end

    def authoritative?(leg)
      binding = @bindings.fetch(leg[:observation].external_account_id)
      binding["publication"] == "ledger" && binding["account_id"] == leg[:observation].account_id &&
        Account::SourcePolicy.active.exists?(id: binding["source_policy_version"], account_id: binding["account_id"],
          account_provider_id: binding["account_provider_id"], resource: "transactions")
    end

    def protected_leg?(leg)
      entry, transaction, record = leg.values_at(:entry, :transaction, :record)
      entry.protected_from_sync? || entry.reconciled? || entry.parent_entry_id.present? || entry.child_entries.exists? ||
        transaction[:transfer_id].present? || !transaction.standard? ||
        entry.amount != record[:amount] || entry.currency != record[:currency] || entry.date != record[:date]
    end

    def captured_leg(observation)
      batch, page = captured_page(observation.ingestion_batch_id)
      unless batch.external_account_id == observation.external_account_id && batch.source_binding == @bindings.fetch(observation.external_account_id) &&
          batch.source_binding["account_id"] == observation.account_id && batch.scope_key == "account:#{observation.external_account_id}"
        raise Provider::AccountData::StaleWriter, "Wise transfer source binding changed"
      end
      records = page.records.select { |record| record[:external_id] == observation.input_external_id }
      return unless records.one? && observation.input_external_id == observation.external_id && observation.input_occurrence.zero?
      record = records.sole
      return unless record.kind == "transaction" && record[:pending] == false && page.evidence["phase"] == "activities"
      pairing = (record[:metadata] || {}).with_indifferent_access[:transfer_pair]
      return unless pairing.is_a?(Hash) && pairing[:format] == FORMAT
      account = @inventory.fetch(observation.external_account_id)
      response = page.evidence["response"]
      rows = response.is_a?(Hash) ? response["activities"] || response[:activities] : response
      raise Provider::AccountData::StaleWriter, "Wise activity response is missing" unless rows.is_a?(Array)
      bounded_rows!(rows)
      originals = rows.select do |raw|
        raw.is_a?(Hash) && raw.with_indifferent_access[:id].to_s == pairing[:activity_id]
      end
      return unless originals.one?
      raw = originals.sole
      normalized = adapter.normalize_activity(raw, account: account)
      proof = self.class.proof(raw: raw, profile_id: adapter.statement_profile_id, account: account, amount: record[:amount])
      return unless proof && pairing.slice(*proof.keys).stringify_keys == proof &&
        normalized[:external_id] == record[:external_id] && normalized[:amount] == record[:amount] &&
        normalized[:currency] == record[:currency] && normalized[:date] == record[:date] &&
        pairing[:key] == "wise_interbalance_#{proof.fetch('resource_id')}" &&
        pairing[:role] == (record[:amount].negative? ? "inflow" : "outflow") && pairing[:status] == "confirmed"
      { observation: observation, batch: batch, record: record, proof: proof }
    end

    def captured_page(id)
      return @batches.fetch(id) if @batches.key?(id)
      scope = connection.ingestion_batches.where(id: id, family_id: connection.family_id)
      size = scope.pick(Arel.sql("octet_length(payload)"))
      unless size && size <= MAX_BATCH_BYTES
        raise Provider::AccountData::IncompletePage, "Wise transfer batch exceeds its stored byte bound"
      end
      batch = scope.where("octet_length(payload) <= ?", MAX_BATCH_BYTES).lock("FOR SHARE NOWAIT").first!
      @bytes += size
      payload = batch.payload
      @bytes += JSON.generate(payload).bytesize
      if @bytes > MAX_TOTAL_BYTES || JSON.generate(payload).bytesize > MAX_BATCH_BYTES
        raise Provider::AccountData::IncompletePage, "Wise transfer evidence exceeds its decoded byte bound"
      end
      unless batch.applied? && batch.origin_kind == "provider" && batch.stream == "transactions" && batch.provider_authorization_id.nil? &&
          batch.provider_sync_generation_id.nil? && batch.sync&.syncable_type == "ProviderConnection" && batch.sync.syncable_id == connection.id
        raise Provider::AccountData::StaleWriter, "Wise transfer needs an applied native account batch"
      end
      page = Ingestion::Codec.load(payload)
      Provider::AccountData::RequestGrant.verify_capture!(connection: connection,
        capture: page.evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY], require_runtime_inputs: true, scope_sync: batch.sync)
      input = page.evidence[Provider::AccountData::RequestInputs::EVIDENCE_KEY]
      unless input.is_a?(Hash) && input["version"] == 1 && input["scope"] == {
          "connection_id" => connection.id, "family_id" => connection.family_id, "sync_id" => batch.sync_id,
          "stream" => "transactions", "external_account_id" => batch.external_account_id,
          "identity_namespace" => "connection", "request_key" => batch.idempotency_key } &&
          input["source_binding"] == Provider::AccountData::RuntimeInputs.fingerprint(batch.source_binding, purpose: "provider-request-inputs/v1")
        raise Provider::AccountData::StaleWriter, "Wise transfer has no original account request proof"
      end
      @batches[id] = [ batch, page ]
    end
end
