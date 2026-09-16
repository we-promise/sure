require "digest"
require "securerandom"

# Durable enumeration of cached observations, not financial publication. Every
# physical occurrence survives; recording an upsert never proves it was applied.
class Provider::AccountData::Plaid::CachedChangeJournal
  class Conflict < StandardError; end

  FORMAT = "plaid-cached-change-journal/v1".freeze
  STREAM = "legacy_plaid_cached_changes".freeze
  EMPTY_DIGEST = Digest::SHA256.hexdigest(FORMAT).freeze
  MAX_BYTES = 40 * 1024 * 1024
  MAX_STATE_BYTES = 256 * 1024
  Result = Data.define(:phase, :checkpoint_id, :batch_id, :context, :captured_pages, :verified_pages, :observations, :blockers, :replayed) do
    def recorded?
      phase == "recorded"
    end

    def inspect
      "#<#{self.class.name} phase=#{phase} pages=#{captured_pages}>"
    end
  end

  def initialize(control:, family:, page_size: 100)
    unless control.is_a?(ProviderMigrationControl) && control.persisted? && family.is_a?(Family) && family.persisted? &&
        control.provider_key == "plaid" && control.legacy_type == "PlaidItem" && control.family_id == family.id &&
        page_size.is_a?(Integer) && (1..500).cover?(page_size)
      raise ArgumentError, "Cached changes require a Plaid control, authorized family and bounded page size"
    end
    @control_id, @family_id, @page_size = control.id, family.id, page_size
  end

  def run
    admitted do
      load_checkpoint!
      page = plan(cursor: state["cursor"])
      bind_context!(page)
      if state["phase"] == "recorded"
        verify_inventory!
        next result(replayed: true)
      end
      policy = source_policy(page)
      if state["phase"] == "capture"
        capture_page!(page, policy)
      else
        verify_page!(page, policy)
      end
      save_checkpoint!
      result(replayed: state["phase"] != "capture" && @published_batch.nil?)
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Reverification retains all original pages, signatures and counters. It never
  # recaptures changed data or resets the copied provider cursor.
  def restart_verification!
    admitted do
      load_checkpoint!(required: true)
      raise Conflict, "Finish capturing cached changes before reverification" unless %w[verify recorded].include?(state["phase"])
      bind_context!(plan(cursor: nil))
      verify_inventory!
      state.merge!("phase" => "verify", "cursor" => nil, "verified_pages" => 0,
        "verification_digest" => EMPTY_DIGEST, "verified_observations" => 0, "verified_blockers" => 0)
      save_checkpoint!
      result(replayed: true)
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    Plan = Provider::AccountData::Plaid::CheckpointBootstrapPlan
    Value = Provider::AccountData::MigrationValue
    Keys = Ingestion::IdentitySigningKeys
    Fence = Provider::AccountData::LegacyWriterFence
    attr_reader :control, :connection, :family, :checkpoint, :state

    def admitted
      raise Conflict, "Configure encryption before recording cached changes" unless ActiveRecordEncryptionConfig.ready?
      selected = ProviderMigrationControl.find_by!(id: @control_id, family_id: @family_id, provider_key: "plaid", legacy_type: "PlaidItem")
      item = PlaidItem.find_by!(id: selected.legacy_id, family_id: @family_id)
      Fence.with_exclusive(item) do
        ApplicationRecord.uncached do
          ApplicationRecord.transaction do
            @published_batch = nil
            @control = ProviderMigrationControl.lock.find_by!(id: @control_id, family_id: @family_id, provider_key: "plaid", legacy_type: "PlaidItem")
            @connection = ProviderConnection.lock.find_by!(id: control.provider_connection_id, family_id: @family_id, provider_key: "plaid")
            # Refuse contention rather than waiting in reverse family/account
            # lock order. Nested planner locks remain held through publication.
            @family = Family.lock("FOR SHARE NOWAIT").find(@family_id)
            Setting.connection.execute("LOCK TABLE #{Setting.connection.quote_table_name(Setting.table_name)} IN SHARE MODE")
            yield
          end
        end
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::LockWaitTimeout, Plan::Conflict,
        Provider::AccountData::MigrationCopier::Conflict, Keys::InvalidSignature, Keys::InvalidConfiguration,
        KeyError, TypeError, ArgumentError
      raise Conflict, "Cached-change evidence or its original migration context is unavailable or changed", cause: nil
    end

    def plan(cursor:)
      Plan.new(control: control, family: family).page(cursor: cursor, limit: @page_size)
    end

    def checkpoint_scope
      connection.provider_sync_checkpoints.where(family_id: @family_id, stream: STREAM, scope_key: "connection")
    end

    def batches
      connection.ingestion_batches.where(stream: STREAM)
    end

    def load_checkpoint!(required: false)
      @retained_tail = nil
      @checkpoint = checkpoint_scope.lock.select(:id).first
      unless checkpoint
        raise Conflict, "Cached-change pages require their original checkpoint" if required || batches.exists?
        @checkpoint = checkpoint_scope.new(id: SecureRandom.uuid, schema_version: 1)
        @state = { "format" => FORMAT, "checkpoint_id" => checkpoint.id, "phase" => "capture", "page_size" => @page_size,
          "context" => nil, "cursor" => nil, "captured_pages" => 0, "verified_pages" => 0,
          "observations" => 0, "blockers" => 0, "verified_observations" => 0, "verified_blockers" => 0,
          "capture_digest" => EMPTY_DIGEST, "verification_digest" => EMPTY_DIGEST,
          "cursor_accepted" => false, "requires_cutover_reverification" => true }
        return
      end
      bytes = checkpoint_scope.pick(Arel.sql("octet_length(state)"))
      raise Conflict, "Cached-change checkpoint exceeds its read bound" unless bytes && bytes <= MAX_STATE_BYTES * 2
      @checkpoint = checkpoint_scope.where("octet_length(state) <= ?", MAX_STATE_BYTES * 2).first!
      unless checkpoint.schema_version == 1 &&
          checkpoint.external_account_id.nil? && checkpoint.provider_authorization_id.nil? && checkpoint.provider_sync_generation_id.nil? &&
          checkpoint.cursor.nil? && checkpoint.covered_through.nil?
        raise Conflict, "Cached-change checkpoint has unrelated or oversized execution state"
      end
      stored_state = checkpoint.state
      unless stored_state.is_a?(Hash) && Value.dump(stored_state).bytesize <= MAX_STATE_BYTES
        raise Conflict, "Cached-change checkpoint exceeds its decoded bound"
      end
      @state = stored_state.deep_dup
      unless state.is_a?(Hash) && state.keys.sort == %w[blockers capture_digest captured_pages checkpoint_id context cursor cursor_accepted format observations page_size phase requires_cutover_reverification verification_digest verified_blockers verified_observations verified_pages] &&
          state["format"] == FORMAT && state["checkpoint_id"] == checkpoint.id && state["page_size"] == @page_size &&
          %w[capture verify recorded].include?(state["phase"]) && state["context"].is_a?(Hash) &&
          (state["cursor"].nil? || state["cursor"].is_a?(Hash)) && state["cursor_accepted"] == false && state["requires_cutover_reverification"] == true &&
          %w[captured_pages verified_pages observations blockers verified_observations verified_blockers].all? { |key| state[key].is_a?(Integer) && state[key] >= 0 } &&
          state["captured_pages"].positive? && state["verified_pages"] <= state["captured_pages"] &&
          state["verified_observations"] <= state["observations"] && state["verified_blockers"] <= state["blockers"] &&
          %w[capture_digest verification_digest].all? { |key| state[key].is_a?(String) && state[key].match?(/\A[0-9a-f]{64}\z/) }
        raise Conflict, "Cached-change checkpoint has invalid retained progress"
      end
      verify_inventory!
      tail, payload = retained_page(state.fetch("captured_pages") - 1)
      @retained_tail = payload
      unless checkpoint.ingestion_batch_id == tail.id && digest(payload) == state["capture_digest"]
        raise Conflict, "Cached-change checkpoint lost its original final page"
      end
      if state["phase"] == "capture"
        unless state["verified_pages"].zero? && state["verification_digest"] == EMPTY_DIGEST &&
            state["verified_observations"].zero? && state["verified_blockers"].zero? &&
            !payload.fetch("plan").fetch("complete") && state["cursor"] == payload["cursor_out"]
          raise Conflict, "Cached-change capture position differs from its retained page"
        end
      elsif !payload.fetch("plan").fetch("complete") || payload["cursor_out"]
        raise Conflict, "Cached-change verification requires a terminal captured page"
      elsif state["phase"] == "recorded"
        require_verified_totals!
        raise Conflict, "Recorded journal has an unfinished continuation" if state["cursor"]
      elsif state["verified_pages"].zero?
        unless state["cursor"].nil? && state["verification_digest"] == EMPTY_DIGEST && state["verified_observations"].zero? && state["verified_blockers"].zero?
          raise Conflict, "Cached-change verification must start at the first observation"
        end
      else
        _, prior = retained_page(state.fetch("verified_pages") - 1)
        unless state["cursor"] == prior["cursor_out"] && state["verification_digest"] == digest(prior) && state["verified_pages"] < state["captured_pages"]
          raise Conflict, "Cached-change verification position differs from its retained page"
        end
      end
    end

    def bind_context!(page)
      context = page.document.fetch("context")
      if state["context"] && state["context"] != context
        raise Conflict, "Cached-change journal belongs to another copy or processing configuration"
      end
      state["context"] ||= context.deep_dup
    end

    def source_policy(page)
      source = page.document["source_account"]
      return nil unless source && source["account_id"]
      account = Account.lock("FOR UPDATE NOWAIT").find_by!(id: source.fetch("account_id"), family_id: @family_id)
      policy = Account::SourcePolicy.active.find_by(account: account, family_id: @family_id, resource: "transactions")
      { "account_id" => account.id, "account_provider_id" => source.fetch("account_provider_id"),
        "source_policy_id" => policy&.id, "revision" => policy&.revision,
        "selected_account_provider_id" => policy&.account_provider_id,
        "disposition" => policy.nil? ? "authority_unselected" : policy.account_provider_id == source["account_provider_id"] ? "selected_source" : "secondary_source" }
    end

    def page_values(page, policy)
      { "cursor_in" => state["cursor"], "cursor_out" => page.next_cursor, "plan" => page.document, "source_policy" => policy }
    end

    def capture_page!(page, policy)
      if @retained_tail && @retained_tail.dig("plan", "source_account", "mapping_id") == page.document.dig("source_account", "mapping_id") &&
          @retained_tail["source_policy"] != policy
        raise Conflict, "Cached account authority changed during journal capture"
      end
      sequence = state.fetch("captured_pages")
      batch_id = SecureRandom.uuid
      payload = page_values(page, policy).merge("format" => FORMAT, "checkpoint_id" => checkpoint.id,
        "batch_id" => batch_id, "sequence" => sequence, "previous_digest" => state.fetch("capture_digest"))
      payload["signature"] = Keys.configured.sign(Value.dump(payload))
      raise Conflict, "Cached-change page exceeds its evidence bound" if Value.dump(payload).bytesize > MAX_BYTES
      @published_batch = batches.create!(id: batch_id, family_id: @family_id, origin_kind: "migration", scope_key: "connection",
        sequence: sequence, idempotency_key: "#{STREAM}:#{checkpoint.id}:#{sequence}", schema_version: 1,
        mode: "unknown", complete: false, coverage: {}, ruleset_snapshot: {}, source_binding: {},
        payload: { "format" => FORMAT, "document" => Value.dump(payload) },
        status: "applied", applied_at: Time.current)
      state["captured_pages"] += 1
      state["observations"] += page.document.fetch("observations").size
      state["blockers"] += page.document.fetch("blockers").size
      state["capture_digest"] = digest(payload)
      state["cursor"] = page.next_cursor
      state["phase"] = "verify" if page.complete
      checkpoint.ingestion_batch = @published_batch
    end

    def verify_page!(page, policy)
      _, payload = retained_page(state.fetch("verified_pages"))
      unless payload.slice("cursor_in", "cursor_out", "plan", "source_policy") == page_values(page, policy) &&
          payload["previous_digest"] == state["verification_digest"]
        raise Conflict, "Cached-change page differs from its original observations or authority"
      end
      state["verified_pages"] += 1
      state["verified_observations"] += page.document.fetch("observations").size
      state["verified_blockers"] += page.document.fetch("blockers").size
      state["verification_digest"] = digest(payload)
      state["cursor"] = page.next_cursor
      if page.complete
        verify_inventory!
        require_verified_totals!
        state["phase"] = "recorded"
      end
    end

    def retained_page(sequence)
      scope = batches.where(sequence: sequence)
      raise Conflict, "Cached-change page sequence is missing or repeated" unless scope.count == 1
      bytes = scope.pick(Arel.sql("octet_length(payload)"))
      raise Conflict, "Cached-change page is oversized" unless bytes && bytes <= MAX_BYTES * 2
      batch = scope.where("octet_length(payload) <= ?", MAX_BYTES * 2).first!
      unless batch.family_id == @family_id && batch.origin_kind == "migration" && batch.scope_key == "connection" && batch.applied? && batch.applied_at &&
          batch.schema_version == 1 && batch.mode == "unknown" && !batch.complete? && batch.coverage == {} && batch.ruleset_snapshot == {} && batch.source_binding == {} &&
          batch.attributes.values_at("sync_id", "import_id", "account_statement_id", "external_account_id", "provider_authorization_id", "provider_sync_generation_id", "writer_epoch", "source_policy_version", "generation_role", "generation_resource").all?(&:nil?) &&
          batch.idempotency_key == "#{STREAM}:#{checkpoint.id}:#{sequence}"
        raise Conflict, "Cached-change page has unrelated publication context"
      end
      wrapper = batch.payload
      unless wrapper.is_a?(Hash) && wrapper.keys.sort == %w[document format] && wrapper["format"] == FORMAT &&
          wrapper["document"].is_a?(String) && wrapper["document"].bytesize <= MAX_BYTES
        raise Conflict, "Cached-change page lost its typed document"
      end
      payload = Value.load(wrapper.fetch("document"))
      unless payload.is_a?(Hash) && payload.keys.sort == %w[batch_id checkpoint_id cursor_in cursor_out format plan previous_digest sequence signature source_policy] &&
          payload["format"] == FORMAT && payload["checkpoint_id"] == checkpoint.id && payload["batch_id"] == batch.id && payload["sequence"] == sequence &&
          payload.dig("plan", "context") == state["context"] && payload.dig("plan", "cursor_accepted") == false &&
          Value.dump(payload).bytesize <= MAX_BYTES
        raise Conflict, "Cached-change page lost its original journal identity"
      end
      Keys.configured.verify!(payload.fetch("signature"), Value.dump(payload.except("signature")))
      [ batch, payload ]
    end

    def verify_inventory!
      count = state.fetch("captured_pages")
      unless batches.count == count && batches.distinct.count(:sequence) == count &&
          (count.zero? || (batches.minimum(:sequence).zero? && batches.maximum(:sequence) == count - 1))
        raise Conflict, "Cached-change page inventory is incomplete or contains unrelated evidence"
      end
    end

    def require_verified_totals!
      unless state["verified_pages"] == state["captured_pages"] && state["verified_observations"] == state["observations"] &&
          state["verified_blockers"] == state["blockers"] && state["verification_digest"] == state["capture_digest"]
        raise Conflict, "Cached-change verification did not cover its full original inventory"
      end
    end

    def save_checkpoint!
      raise Conflict, "Cached-change progress exceeds its bound" if Value.dump(state).bytesize > MAX_STATE_BYTES
      checkpoint.update!(state: state)
    end

    def digest(payload)
      Digest::SHA256.hexdigest(Value.dump(payload))
    end

    def result(replayed:)
      Result.new(phase: state.fetch("phase"), checkpoint_id: checkpoint.id, batch_id: checkpoint.ingestion_batch_id,
        context: Provider::AccountData::MigrationManifest.copy_value(state.fetch("context")), captured_pages: state.fetch("captured_pages"),
        verified_pages: state.fetch("verified_pages"), observations: state.fetch("observations"), blockers: state.fetch("blockers"), replayed: replayed)
    end

    def capture_failure(error)
      return if error.is_a?(Fence::Busy)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", message: "Plaid cached-change journal requires review",
        source: self.class.name, provider_key: "plaid", family_id: @family_id,
        metadata: { migration_control_id: @control_id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
