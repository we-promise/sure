# The profile-wide decision is made before any account consumes a statement.
# A successful first window (including an empty one) permanently vetoes fallback
# for this Sync. Later windows may fail, but cannot undo that observed success.
class Provider::AccountData::Wise::StatementBarrier
  FORMAT = "wise-statement-barrier/v1"
  STREAM = "wise_statement_barrier"
  MAX_ACCOUNTS = 100
  MAX_PAGE_BYTES = 4.megabytes
  MAX_TOTAL_BYTES = 32.megabytes
  REQUESTS_PER_RUN = 16

  def initialize(connection:, sync:, adapter:, writer_epoch:, fence:, request_grant:, record_builder:, window_builder:)
    @connection, @sync, @adapter, @writer_epoch = connection, sync, adapter, writer_epoch
    @fence, @grant, @record_builder, @window_builder = fence, request_grant, record_builder, window_builder
    @bytes = 0
  end

  def perform
    @header = load_batch(key("manifest")) || capture_manifest!
    @manifest = Ingestion::Codec.load(@header.payload)
    @context = @manifest.evidence.fetch("wise_statement_barrier")
    @fingerprint = fingerprint(@context)
    verify_manifest!
    probes = {}
    requests = 0
    @manifest.records.each do |record|
      next unless adapter.standard_statement_account?(record)
      external_id = record[:metadata].fetch("runtime_external_account_id")
      captured = load_batch(key("probe", external_id))
      unless captured
        if requests >= REQUESTS_PER_RUN
          raise Provider::AccountData::DeferredPage.new(resume_at: 15.seconds.from_now)
        end
        requests += 1
        page, capture = @grant.capture_request(scope_sync: sync, admit: -> { verify_current! }) do
          adapter.probe_statement(account: record, window: window_for(external_id))
        end
        page = Provider::AccountData::RequestGrant.attach(page, capture)
        captured = @fence.call do
          verify_current!
          verify_grant!(page)
          create_batch!(page, role: "probe", external_id: external_id)
        end
      end
      page = read_probe!(captured, external_id)
      probes[record[:external_id]] = { "batch_id" => captured.id, "page" => page }
    end
    @fence.call { verify_current! }
    adapter.bind_statement_barrier!(probes: probes, windows: @context.fetch("accounts").transform_values { |value| value.fetch("window") },
      header_id: @header.id, fingerprint: @fingerprint)
    self
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Wise statement barrier is invalid", cause: nil
  end

  def window_for(external_id)
    @context.fetch("accounts").fetch(external_id).fetch("window")
  end

  # Financial pair finalization uses the same complete profile inventory, grant
  # and ordered account locks as statement admission. No I/O is allowed here.
  def with_verified_inventory
    @fence.call do
      verify_current!
      yield @manifest.records, @context.fetch("accounts")
    end
  end

  private
    attr_reader :connection, :sync, :adapter

    def key(role, external_id = nil)
      Digest::SHA256.hexdigest([ FORMAT, sync.id, role, external_id ].join(":"))
    end

    def scope(role, external_id)
      external_id ? "wise_statement_#{role}:#{external_id}" : "connection"
    end

    def fingerprint(value)
      Provider::AccountData::RuntimeInputs.fingerprint(value, purpose: FORMAT)
    end

    def configuration(external)
      { "connection_start" => connection.sync_start_date&.iso8601, "external_start" => external.sync_start_date&.iso8601,
        "sync_start" => sync.window_start_date&.iso8601, "sync_end" => sync.window_end_date&.iso8601,
        "observed_at" => sync.created_at.getutc.iso8601(6) }
    end

    def resolver
      Provider::AccountData::GenerationAccounts.new(connection)
    end

    def externals
      values = connection.external_accounts.where(identity_namespace: "connection").order(:id).limit(MAX_ACCOUNTS + 1).to_a
      raise Provider::AccountData::IncompletePage, "Wise profile exceeds the statement inventory limit" if values.size > MAX_ACCOUNTS
      values
    end

    def checkpoint(external_id)
      connection.provider_sync_checkpoints.find_by(stream: "transactions", scope_key: "account:#{external_id}")
    end

    def capture_manifest!
      page, capture = @grant.capture_request(scope_sync: sync, admit: lambda {
        @fence.call do
          current = externals
          bindings = resolver.capture
          records = []
          accounts = current.to_h do |external|
            current_checkpoint = checkpoint(external.id)
            records << @record_builder.call(external) if external.active?
            [ external.id, { "binding" => bindings.fetch(external.external_id), "configuration" => configuration(external),
              "checkpoint" => fingerprint(current_checkpoint&.attributes),
              "window" => @window_builder.call(external, current_checkpoint) } ]
          end
          Provider::AccountData::Page.new(records: records, complete: false, mode: "snapshot", evidence: {
            "wise_statement_barrier" => { "format" => FORMAT, "family_id" => connection.family_id,
              "connection_id" => connection.id, "sync_id" => sync.id, "profile_id" => adapter.statement_profile_id,
              "accounts" => accounts }
          })
        end
      }) { |manifest| manifest }
      page = Provider::AccountData::RequestGrant.attach(page, capture)
      @fence.call do
        verify_grant!(page)
        @context = page.evidence.fetch("wise_statement_barrier")
        @fingerprint = fingerprint(@context)
        header = create_batch!(page, role: "manifest")
        # Route every original owner atomically with the connection manifest,
        # including balances not yet probed or linked to the financial ledger.
        @context.fetch("accounts").each_key do |external_id|
          route = Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
            evidence: { "wise_statement_manifest" => { "header_id" => header.id, "fingerprint" => @fingerprint } })
          create_batch!(route, role: "manifest", external_id: external_id)
        end
        header
      end
    end

    def verify_manifest!
      unless @context.is_a?(Hash) && @context.keys.sort == %w[accounts connection_id family_id format profile_id sync_id] &&
          @context.values_at("format", "family_id", "connection_id", "sync_id", "profile_id") ==
            [ FORMAT, connection.family_id, connection.id, sync.id, adapter.statement_profile_id ] &&
          @context["accounts"].is_a?(Hash) && @context["accounts"].size <= MAX_ACCOUNTS &&
          @manifest.records.all? { |record| record.kind == "account" } && !@manifest.complete?
        raise Provider::AccountData::StaleWriter, "Wise statement manifest belongs to another scope"
      end
      @context.fetch("accounts").each_key do |external_id|
        route = load_batch(key("manifest", external_id))
        raise Provider::AccountData::StaleWriter, "Wise statement manifest has a missing owner" unless route
        verify_batch!(route, role: "manifest", external_id: external_id)
        page = Ingestion::Codec.load(route.payload)
        unless page.records.empty? && !page.complete? && page.evidence == {
            "wise_statement_manifest" => { "header_id" => @header.id, "fingerprint" => @fingerprint } }
          raise Provider::AccountData::StaleWriter, "Wise statement manifest routing changed"
        end
      end
      @fence.call do
        verify_batch!(@header, role: "manifest")
        verify_grant!(@manifest)
        verify_current!
      end
    end

    def verify_current!
      @fence.call do
        @grant.verify!
        current = externals
        unless current.map(&:id).sort == @context.fetch("accounts").keys.sort
          raise Provider::AccountData::StaleWriter, "Wise profile inventory changed after statement capture"
        end
        expected = current.to_h do |external|
          [ external.external_id, @context.fetch("accounts").fetch(external.id).fetch("binding") ]
        end
        resolver.with_verified_bindings(expected) do |locked|
          records = []
          locked.each_value do |external|
            original = @context.fetch("accounts").fetch(external.id)
            records << @record_builder.call(external) if external.active?
            current_checkpoint = checkpoint(external.id)
            own_batch_id = current_checkpoint&.state&.dig("progress", "ingestion_batch_id") || current_checkpoint&.ingestion_batch_id
            own_checkpoint = connection.ingestion_batches.select(:id, :sync_id, :status, :stream, :scope_key, :external_account_id).find_by(id: own_batch_id)
            checkpoint_matches = fingerprint(current_checkpoint&.attributes) == original.fetch("checkpoint") ||
              (own_checkpoint&.sync_id == sync.id && own_checkpoint.applied? && own_checkpoint.stream == "transactions" &&
                own_checkpoint.scope_key == "account:#{external.id}" && own_checkpoint.external_account_id == external.id)
            unless original.fetch("configuration") == configuration(external) && checkpoint_matches
              raise Provider::AccountData::StaleWriter, "Wise statement window inputs changed after capture"
            end
          end
          unless records.sort_by { |record| record[:external_id] }.map(&:attributes) == @manifest.records.sort_by { |record| record[:external_id] }.map(&:attributes)
            raise Provider::AccountData::StaleWriter, "Wise statement account inputs changed after capture"
          end
        end
      end
      true
    end

    def create_batch!(page, role:, external_id: nil)
      payload = Ingestion::Codec.dump(page)
      account = external_id && @context.fetch("accounts").fetch(external_id)
      measure!(payload)
      connection.ingestion_batches.create!(family: connection.family, sync: sync, external_account_id: external_id,
        origin_kind: "provider", stream: external_id ? "transactions" : STREAM, scope_key: scope(role, external_id),
        sequence: 0, idempotency_key: key(role, external_id), mode: page.mode, complete: false,
        coverage: {}, payload: payload, ruleset_snapshot: {}, writer_epoch: @writer_epoch,
        source_binding: account ? account.fetch("binding") : {}, source_policy_version: account&.dig("binding", "source_policy_version"))
    end

    def load_batch(idempotency_key)
      relation = connection.ingestion_batches.where(sync: sync, family_id: connection.family_id, idempotency_key: idempotency_key)
      header = relation.pick(:id, Arel.sql("octet_length(payload)"))
      return unless header
      unless header.last && header.last <= MAX_PAGE_BYTES * 2 + 4096
        raise Provider::AccountData::IncompletePage, "Wise statement capture exceeds its stored byte limit"
      end
      batch = relation.where(id: header.first).where("octet_length(payload) <= ?", MAX_PAGE_BYTES * 2 + 4096).first
      raise Provider::AccountData::StaleWriter, "Wise statement capture changed while reading" unless batch
      measure!(batch.payload)
      batch
    end

    def measure!(payload)
      size = JSON.generate(payload).bytesize
      @bytes += size
      if size > MAX_PAGE_BYTES || @bytes > MAX_TOTAL_BYTES
        raise Provider::AccountData::IncompletePage, "Wise statement capture exceeds its decoded byte limit"
      end
    end

    def verify_batch!(batch, role:, external_id: nil)
      expected_binding = external_id ? @context.fetch("accounts").fetch(external_id).fetch("binding") : {}
      unless batch.origin_kind == "provider" && batch.provider_connection_id == connection.id && batch.family_id == connection.family_id &&
          batch.sync_id == sync.id && batch.external_account_id == external_id && batch.provider_authorization_id.nil? &&
          batch.stream == (external_id ? "transactions" : STREAM) && batch.scope_key == scope(role, external_id) &&
          batch.idempotency_key == key(role, external_id) && batch.source_binding == expected_binding &&
          batch.source_policy_version == expected_binding["source_policy_version"] && batch.sequence.zero? &&
          batch.captured? && !batch.complete? && batch.mode == "snapshot" && batch.coverage == {} &&
          batch.writer_epoch <= @writer_epoch && batch.provider_sync_generation_id.nil?
        raise Provider::AccountData::StaleWriter, "Wise statement capture has changed ownership"
      end
    end

    def verify_grant!(page)
      Provider::AccountData::RequestGrant.verify_capture!(connection: connection,
        capture: page.evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY],
        require_runtime_inputs: @grant.runtime_inputs?, scope_sync: sync)
    end

    def read_probe!(batch, external_id)
      verify_batch!(batch, role: "probe", external_id: external_id)
      page = Ingestion::Codec.load(batch.payload)
      @fence.call { verify_grant!(page) }
      proof = page.evidence.fetch("wise_statement_probe")
      unless proof == { "profile_id" => adapter.statement_profile_id, "external_account_id" => external_id,
          "window" => window_for(external_id), "outcome" => proof["outcome"] } && %w[success denied].include?(proof["outcome"])
        raise Provider::AccountData::StaleWriter, "Wise statement probe belongs to another request"
      end
      account = @manifest.records.find { |record| record[:metadata]["runtime_external_account_id"] == external_id }
      valid = if proof["outcome"] == "denied"
        page.records.empty? && !page.complete? && page.next_cursor.nil? && page.coverage.empty? &&
          %w[access_forbidden not_found].include?(page.evidence["error_type"])
      else
        account && page.records.all? { |record| record.kind == "transaction" } && page.evidence["phase"] == "statements" &&
          page.evidence["wise_account"] == { "profile_id" => adapter.statement_profile_id,
            "external_id" => account[:external_id], "currency" => account[:currency] } &&
          !page.complete? && page.next_cursor.present?
      end
      raise Provider::AccountData::StaleWriter, "Wise statement probe has no valid outcome" unless valid
      page
    end
end
