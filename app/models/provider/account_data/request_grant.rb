# Pins the database grant used to construct an adapter. Only a successful
# CredentialStore operation in the active request can advance its credential
# revision; observing a new database revision never authorizes rebinding.
class Provider::AccountData::RequestGrant
  EVIDENCE_KEY = "request_grant"
  MAX_AUTHORIZATIONS = 10_000
  MAX_MEMBERSHIPS = 20_000
  MAX_ROTATIONS = 64

  attr_reader :snapshot

  def runtime_inputs?
    @runtime_inputs.present?
  end

  def invalidate!
    @invalidated = true
  end

  def initialize(connection, runtime_inputs: nil, execution: nil)
    @connection = connection
    @runtime_inputs = runtime_inputs
    bind_execution!(execution) if execution
  end

  # The live worker token is separate from replayable request evidence. Recovery
  # keeps the latter, but an old grant may never adopt a replacement worker.
  def bind_execution!(execution)
    unless execution.is_a?(Provider::AccountData::SyncExecution) && execution.connection.id == @connection.id &&
        execution.revision && (!@execution || @execution.equal?(execution)) && !@request
      raise Provider::AccountData::StaleWriter, "Request grant cannot change provider execution"
    end
    bind_sync!(execution.sync)
    @execution = execution
    self
  end

  def assert_connection!(connection)
    unless connection.id == @connection.id && connection.family_id == @connection.family_id && connection.provider_key == @connection.provider_key
      raise Provider::AccountData::StaleWriter, "Request grant belongs to another provider connection"
    end
    self
  end

  def capture!(scope_sync: nil)
    bind_sync!(scope_sync) if scope_sync
    with_adapter_snapshot { }
    self
  end

  # Factories only construct clients and normalize context; they must not perform
  # HTTP. Keep the same grant rows locked through those credential/context reads.
  def with_adapter_snapshot(adapter: nil, observed_at: nil, sync: nil)
    bind_sync!(sync) if sync
    if adapter
      raise Provider::AccountData::StaleWriter, "Adapter context has already been constructed" if @runtime_inputs
      @runtime_inputs = Provider::AccountData::RuntimeInputs.new(@connection, adapter: adapter, observed_at: observed_at, sync: sync)
    end
    with_current_snapshot(capture_inputs: !!adapter) do |current|
      raise Provider::AccountData::StaleWriter, "Adapter grant was already captured" if snapshot && snapshot != current
      @snapshot = current
      result = yield @connection, @runtime_inputs&.context
      @runtime_inputs&.verify!
      result
    end
  end

  def verify!
    with_current_snapshot do |current|
      unless snapshot && snapshot == current
        raise Provider::AccountData::StaleWriter, "Adapter authorization changed after construction"
      end
    end
    true
  end

  # Return the result and immutable runtime evidence. A changed grant after HTTP
  # is rejected at publication, after the response can be retained for review.
  def capture_request(scope_sync: nil, admit: nil, receipt_scope: nil)
    capturing = false
    raise Provider::AccountData::StaleWriter, "Provider requests cannot overlap" if @request
    bind_sync!(scope_sync) if scope_sync
    receipt = nil
    admitted = with_current_snapshot do |current|
      unless snapshot && snapshot == current
        raise Provider::AccountData::StaleWriter, "Adapter authorization changed after construction"
      end
      receipt = ProviderCredentialReceipt.admit!(connection: @connection, scope: receipt_scope, snapshot: current) if receipt_scope
      admit&.call
    end
    @request = { "before" => snapshot, "rotations" => [] }
    @request.merge!("receipt_scope" => receipt, "receipt_ids" => []) if receipt
    capturing = true
    result = yield admitted
    capture = { "version" => 1, "before" => @request.fetch("before"), "after" => snapshot,
      "rotations" => @request.fetch("rotations") }
    if receipt
      capture.merge!("version" => 2, "receipt_ids" => @request.fetch("receipt_ids"),
        "recovered_receipt_ids" => receipt.fetch("recovered_receipt_ids"))
    end
    [ result, copy(capture) ]
  ensure
    @request = nil if capturing
  end

  # Bound credential stores cannot lend their credentials to another execution.
  def verify_credential_access!
    raise Provider::AccountData::StaleWriter, "Credential access requires its active provider request" unless @request
    with_current_snapshot do |current|
      raise Provider::AccountData::StaleWriter, "Adapter authorization changed after construction" unless snapshot == current
      ProviderCredentialReceipt.verify_live_scope!(connection: @connection, scope: @request.fetch("receipt_scope")) if @request["receipt_scope"]
    end
  end

  # Called inside CredentialStore's connection transaction, after its guarded
  # save. The comparison admits exactly that save's credential revision change.
  def accept_credential_rotation!(from_revision:, kind:)
    unless @request && %w[refresh session].include?(kind) && from_revision == snapshot.dig("connection", "credential_revision") &&
        @request.fetch("rotations").size < MAX_ROTATIONS
      raise Provider::AccountData::StaleWriter, "Credential rotation has no request ownership"
    end
    with_current_snapshot do |current|
      expected = snapshot.deep_dup
      expected.fetch("connection")["credential_revision"] = from_revision + 1
      unless current == expected
        raise Provider::AccountData::StaleWriter, "Credential rotation also changed the provider grant"
      end
      if @request["receipt_scope"]
        receipt = ProviderCredentialReceipt.record!(connection: @connection, scope: @request.fetch("receipt_scope"),
          before: snapshot, after: current, ordinal: @request.fetch("rotations").size, kind: kind)
        @request.fetch("receipt_ids") << receipt.id
      end
      @request.fetch("rotations") << { "kind" => kind, "from_revision" => from_revision, "to_revision" => from_revision + 1 }
      @snapshot = current
    end
  end

  def self.verify_capture!(connection:, capture:, require_runtime_inputs: false, scope_sync: nil)
    with_verified_capture!(connection: connection, capture: capture, require_runtime_inputs: require_runtime_inputs, scope_sync: scope_sync) { true }
  end

  # Publication may need to keep this entire lock plan held before acquiring
  # financial Account/child locks. The block must not perform external I/O.
  def self.with_verified_capture!(connection:, capture:, require_runtime_inputs: false, scope_sync: nil)
    validate_capture!(capture)
    if capture["version"] == 2
      raise Provider::AccountData::StaleWriter, "Credential receipts require generation-chain verification"
    end
    inputs = capture.dig("after", "runtime_inputs")
    raise Provider::AccountData::StaleWriter, "Response has no captured normalization inputs" if require_runtime_inputs && !inputs
    grant = new(connection, runtime_inputs: inputs && Provider::AccountData::RuntimeInputs.restore(connection, inputs))
    grant.with_adapter_snapshot(sync: scope_sync) do
      unless grant.snapshot == capture.fetch("after")
        raise Provider::AccountData::StaleWriter, "Captured response authorization is no longer current"
      end
      yield
    end
  end

  def self.verify_snapshot!(connection:, snapshot:, require_runtime_inputs: false, scope_sync: nil)
    inputs = snapshot.is_a?(Hash) && snapshot["runtime_inputs"]
    raise Provider::AccountData::StaleWriter, "Generation has no captured normalization inputs" if require_runtime_inputs && !inputs
    unless snapshot.is_a?(Hash) && new(connection, runtime_inputs: inputs && Provider::AccountData::RuntimeInputs.restore(connection, inputs)).capture!(scope_sync: scope_sync).snapshot == snapshot
      raise Provider::AccountData::StaleWriter, "Captured generation authorization is no longer current"
    end
    true
  end

  # A multi-request generation may rotate cookies after each read. Every change
  # must be proved by a contiguous captured request; an observed new revision is
  # not proof. A resumed factory may recapture its clock, but no other input can
  # change. Validate the final grant against live ownership under the usual locks.
  def self.verify_chain!(connection:, initial_snapshot:, captures:, require_runtime_inputs: false, scope_sync: nil, generation: nil, current_snapshot: nil)
    unless captures.is_a?(Array) && captures.size <= Ingestion::TransactionGroupAssembler::MAX_PAGES
      raise Provider::AccountData::StaleWriter, "Invalid generation authorization chain"
    end
    expected = initial_snapshot
    captures.each_with_index do |capture, index|
      validate_capture!(capture)
      if capture["version"] == 2
        raise Provider::AccountData::StaleWriter, "Credential receipts require their original generation" unless generation
        ProviderCredentialReceipt.verify_capture!(connection: connection, generation: generation, page_sequence: index,
          expected: expected, capture: capture)
      elsif !same_chain_snapshot?(expected, capture.fetch("before"))
        raise Provider::AccountData::StaleWriter, "Generation request authorization is not contiguous"
      end
      expected = capture.fetch("after")
    end
    if current_snapshot && !same_chain_snapshot?(expected, current_snapshot)
      unless generation && captures.size == generation.page_count
        raise Provider::AccountData::StaleWriter, "Generation authorization has an unrelated credential transition"
      end
      ProviderCredentialReceipt.recover!(connection: connection, generation: generation, page_sequence: generation.page_count,
        before: expected, after: current_snapshot)
      expected = current_snapshot
    end
    verify_snapshot!(connection: connection, snapshot: expected, require_runtime_inputs: require_runtime_inputs, scope_sync: scope_sync)
    true
  end

  def self.attach(result, capture)
    validate_capture!(capture)
    unless result.is_a?(Provider::AccountData::Page) || result.is_a?(Provider::AccountData::TransactionGroup)
      raise Provider::AccountData::InvalidResponse, "Provider request did not return a supported page"
    end
    evidence_sets = [ result.evidence ]
    evidence_sets += result.account_pages.values.map(&:evidence) if result.is_a?(Provider::AccountData::TransactionGroup)
    if evidence_sets.any? { |evidence| evidence.keys.any? { |key| [ EVIDENCE_KEY, "request_inputs" ].include?(key.to_s) } }
      raise Provider::AccountData::InvalidResponse, "Provider evidence uses a reserved runtime key"
    end
    evidence = result.evidence.merge(EVIDENCE_KEY => capture)
    if result.is_a?(Provider::AccountData::Page)
      Provider::AccountData::Page.new(records: result.records, complete: result.complete?, mode: result.mode,
        next_cursor: result.next_cursor, checkpoint_cursor: result.checkpoint_cursor, progress_cursor: result.progress_cursor,
        removed_ids: result.removed_ids, coverage: result.coverage, warnings: result.warnings, evidence: evidence)
    else
      Provider::AccountData::TransactionGroup.new(generation_id: result.generation_id, start_cursor: result.start_cursor,
        resource: result.resource,
        request_cursor: result.request_cursor, next_cursor: result.next_cursor, complete: result.complete?,
        account_pages: result.account_pages, unassigned_removed_ids: result.unassigned_removed_ids,
        evidence: evidence, folding_policy: result.folding_policy)
    end
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private

    def self.same_chain_snapshot?(left, right)
      return false unless left.is_a?(Hash) && right.is_a?(Hash) && left.except("runtime_inputs") == right.except("runtime_inputs")
      first, second = left["runtime_inputs"], right["runtime_inputs"]
      return true if first.nil? && second.nil?
      return false unless first.is_a?(Hash) && second.is_a?(Hash) && first.except("frozen_context") == second.except("frozen_context")
      first_frozen, second_frozen = first["frozen_context"], second["frozen_context"]
      first_frozen.is_a?(Hash) && second_frozen.is_a?(Hash) && first_frozen.keys.sort == second_frozen.keys.sort &&
        first_frozen.except("clock") == second_frozen.except("clock")
    end
    private_class_method :same_chain_snapshot?
    def bind_sync!(sync)
      unless sync.persisted? && sync.syncable_type == "ProviderConnection" && sync.syncable_id == @connection.id &&
          (!@scope_sync_id || @scope_sync_id == sync.id)
        raise Provider::AccountData::StaleWriter, "Request sync belongs to another execution"
      end
      @scope_sync_id = sync.id
    end

    def self.validate_capture!(capture)
      receipt_keys = capture.is_a?(Hash) && capture["version"] == 2 ? %w[receipt_ids recovered_receipt_ids] : []
      unless capture.is_a?(Hash) && capture.keys.sort == (%w[after before rotations version] + receipt_keys).sort && [ 1, 2 ].include?(capture["version"]) &&
          capture["before"].is_a?(Hash) && capture["after"].is_a?(Hash) &&
          capture["rotations"].is_a?(Array) && capture["rotations"].size <= MAX_ROTATIONS
        raise Provider::AccountData::StaleWriter, "Response has no captured request authorization"
      end
      if capture["version"] == 2
        unless receipt_keys.all? { |key| capture[key].is_a?(Array) && capture[key].uniq == capture[key] &&
            capture[key].size <= ProviderCredentialReceipt::MAX_PER_PAGE && capture[key].all? { |id| id.is_a?(String) && id.match?(/\A[0-9a-f-]{36}\z/) } } &&
            capture["receipt_ids"].size == capture["rotations"].size
          raise Provider::AccountData::StaleWriter, "Invalid captured credential receipt references"
        end
      end
      before, after = capture.values_at("before", "after")
      unless (before.keys - [ "runtime_inputs" ]).sort == %w[authorizations connection memberships] && after.keys.sort == before.keys.sort &&
          before["connection"].is_a?(Hash) && after["connection"].is_a?(Hash)
        raise Provider::AccountData::StaleWriter, "Invalid captured request authorization"
      end
      revision = before.dig("connection", "credential_revision")
      unless revision.is_a?(Integer) && revision >= 0
        raise Provider::AccountData::StaleWriter, "Invalid captured credential revision"
      end
      capture["rotations"].each do |rotation|
        unless rotation.is_a?(Hash) && rotation.keys.sort == %w[from_revision kind to_revision] &&
            %w[refresh session].include?(rotation["kind"]) && rotation["from_revision"] == revision && rotation["to_revision"] == revision + 1
          raise Provider::AccountData::StaleWriter, "Invalid captured credential transition"
        end
        if capture["version"] == 2 && rotation["kind"] != "session"
          raise Provider::AccountData::StaleWriter, "Credential receipts only recover ordinary session rotations"
        end
        revision += 1
      end
      expected = before.deep_dup
      expected.fetch("connection")["credential_revision"] = revision
      unless expected == after
        raise Provider::AccountData::StaleWriter, "Request credential rotation changed authorization identity"
      end
    end

    def with_current_snapshot(capture_inputs: false, &block)
      raise Provider::AccountData::StaleWriter, "Request credential commit did not finish" if @invalidated
      @connection.with_lock do
        # Queueing and Account handoff lock the provider Sync before Accounts.
        # SHARE also pins the window through admission/publication and remains
        # compatible with the queue's foreign-key/KEY SHARE reads.
        if @scope_sync_id
          current_sync = Sync.where(id: @scope_sync_id, syncable_type: "ProviderConnection", syncable_id: @connection.id).lock("FOR SHARE").first
          raise Provider::AccountData::StaleWriter, "Request sync no longer belongs to its connection" unless current_sync
          @execution&.assert_current!(connection: @connection, current_sync: current_sync)
        end
        if @runtime_inputs
          @runtime_inputs.with_locks { grant_snapshot(capture_inputs: capture_inputs, &block) }
        else
          grant_snapshot(capture_inputs: false, &block)
        end
      end
    end

    def grant_snapshot(capture_inputs:)
      authorizations = @connection.provider_authorizations.where(family_id: @connection.family_id)
        .select(:id, :external_id, :lock_version, :status, :expires_at).order(:id).limit(MAX_AUTHORIZATIONS + 1).lock.to_a
      memberships = ProviderAuthorizationAccount.where(provider_connection_id: @connection.id, family_id: @connection.family_id)
        .order(:id).limit(MAX_MEMBERSHIPS + 1).lock.to_a
      if authorizations.size > MAX_AUTHORIZATIONS || memberships.size > MAX_MEMBERSHIPS
        raise Provider::AccountData::IncompletePage, "Provider authorization inventory exceeds its request bound"
      end
      if @runtime_inputs
        capture_inputs ? @runtime_inputs.capture!(request_grant: self) : @runtime_inputs.verify!
      end
      current = {
        "connection" => @connection.slice("id", "family_id", "provider_key", "external_id", "region", "environment",
          "credential_revision", "status", "scheduled_for_deletion"),
        "authorizations" => authorizations.map do |authorization|
          authorization.slice("id", "external_id", "lock_version", "status").merge(
            "expires_at" => authorization.expires_at&.utc&.iso8601(9), "usable" => authorization.usable?)
        end,
        "memberships" => memberships.map do |membership|
          membership.slice("id", "provider_authorization_id", "external_account_id", "lock_version", "status")
        end }
      current["runtime_inputs"] = @runtime_inputs.evidence if @runtime_inputs
      yield copy(current)
    end

    def copy(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end
end
