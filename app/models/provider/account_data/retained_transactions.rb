require "digest"
require "json"
require "set"

# First financial publication of native observations collected before setup.
# The setup command owns user authorization; this command verifies the current
# publication context and never changes provider cursors or original captures.
class Provider::AccountData::RetainedTransactions
  FORMAT = "retained-transactions/v1".freeze
  MAX_RECORDS = 10_000
  MAX_BATCHES = 256
  MAX_BYTES = 32 * 1024 * 1024

  class Conflict < Provider::AccountData::InvalidResponse; end
  class TooLarge < Conflict; end

  def initialize(external_account:, sync:)
    @external_id = external_account.id
    @connection_id = external_account.provider_connection_id
    @family_id = external_account.family_id
    @sync_id = sync.id
  end

  def call
    raise Conflict, "Retained publication requires the setup transaction" unless ApplicationRecord.connection.transaction_open?

    ApplicationRecord.transaction(requires_new: true) do
      @connection = ProviderConnection.lock("FOR UPDATE NOWAIT").find_by!(id: @connection_id, family_id: @family_id)
      verify_connection!
      @external = connection.external_accounts.find_by!(id: @external_id, family_id: @family_id)
      @sync = connection.syncs.find_by!(id: @sync_id)
      resolver = Provider::AccountData::GenerationAccounts.new(connection, resource: "transactions", identity_namespace: external.identity_namespace)
      binding = resolver.capture_one(external)
      unless binding["publication"] == "ledger" && binding["account_id"].present?
        raise Conflict, "Retained publication requires a visible linked account and source selection"
      end
      resolver.with_verified_binding(external, binding) do |current|
        @external = current
        sync.lock!("FOR UPDATE NOWAIT")
        previous = connection.ingestion_batches.find_by(idempotency_key: receipt_key(binding))
        if previous
          verify_receipt!(previous, binding)
          next previous
        end

        observations = bounded_observations
        captures = bounded_captures
        if observations.empty? && captures.empty? && !external.transaction_backfill_required?
          next nil
        end
        if captures.empty?
          raise Conflict, "Retained backfill has no original transaction captures"
        end
        unless external.identity_namespace == "connection" && sync.pending? && !sync.cancel_requested?
          raise Conflict, "Retained publication requires an unused connection sync"
        end
        if observations.any? { |row| row.account_id.present? } ||
            EntrySource.where(source_record_id: observations.map(&:id)).exists? ||
            HoldingSource.where(source_record_id: observations.map(&:id)).exists?
          raise Conflict, "Retained publication cannot rebind financial history"
        end
        page = compile(observations, captures)
        source = Provider::AccountData::Registry.fetch(external.provider_key).definition.source
        identities = observations.map(&:external_id)
        financial = external.current_account
        if financial.entries.where(source: source, external_id: identities).exists? ||
            (source == "plaid" && financial.entries.where(plaid_id: identities).exists?)
          raise Conflict, "Retained publication cannot claim an existing financial identity"
        end
        batch = connection.ingestion_batches.create!(family_id: @family_id, sync: sync, external_account: external,
          origin_kind: "provider", stream: "transactions", scope_key: "retained-transactions:#{external.id}",
          sequence: 0, idempotency_key: receipt_key(binding), writer_epoch: connection.writer_epoch,
          mode: "delta", complete: true, coverage: page.coverage.as_json, payload: Ingestion::Codec.dump(page),
          ruleset_snapshot: {}, source_policy_version: binding.fetch("source_policy_version"), source_binding: binding)
        Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page, allow_absence: false)
        batch.update!(status: "applied", applied_at: Time.current)
        external.update!(transaction_backfill_required: false)
        batch
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Retained publication context no longer exists", cause: nil
  end

  private
    attr_reader :connection, :external, :sync

    def verify_connection!
      control = ProviderMigrationControl.where(provider_connection_id: connection.id).lock("FOR UPDATE NOWAIT").first
      if control.nil? && (connection.metadata["legacy_id"].present? || connection.metadata["legacy_type"].present? ||
          ProviderMigrationMapping.where(provider_connection_id: connection.id).exists?)
        raise Conflict, "Retained publication is missing its migration ownership context"
      end
      unless connection.good? && !connection.scheduled_for_deletion? && connection.lease_owner.nil? &&
          connection.lease_expires_at.nil? && connection.lease_sync_id.nil? &&
          (!control || (control.family_id == @family_id && control.provider_key == connection.provider_key && control.native_owned?))
        raise Conflict, "Retained publication requires an idle native connection"
      end
      if connection.provider_sync_generations.unfinished.exists?
        raise Conflict, "Retained publication cannot change an unfinished generation binding"
      end
    end

    def receipt_key(binding)
      Digest::SHA256.hexdigest([ FORMAT, external.id, binding.fetch("account_provider_id"), binding.fetch("source_policy_version") ].join(":"))
    end

    def verify_receipt!(batch, binding)
      unless batch.applied? && batch.family_id == @family_id && batch.external_account_id == external.id &&
          batch.origin_kind == "provider" && batch.stream == "transactions" &&
          batch.scope_key == "retained-transactions:#{external.id}" && batch.source_binding == binding &&
          batch.source_policy_version == binding["source_policy_version"] && !external.transaction_backfill_required?
        raise Conflict, "Retained publication receipt differs from the current selection"
      end
      check_stored_bytes!(IngestionBatch.where(id: batch.id))
      page = Ingestion::Codec.load(batch.payload)
      unless page.evidence.dig("retained_transactions", "format") == FORMAT && page.complete? &&
          page.coverage["pending_absence_authoritative"] == false
        raise Conflict, "Retained publication receipt is invalid"
      end
    end

    def bounded_observations
      rows = SourceRecord.where(external_account_id: external.id, kind: "transaction").order(:id)
        .limit(MAX_RECORDS + 1).lock("FOR UPDATE NOWAIT").to_a
      raise TooLarge, "Retained transaction observations exceed the publication bound" if rows.size > MAX_RECORDS
      unless rows.all? { |row| row.family_id == @family_id && row.account_statement_id.nil? && row.input_occurrence.zero? && row.input_external_id == row.external_id }
        raise Conflict, "Retained observations do not have stable native identities"
      end
      rows
    end

    def bounded_captures
      scope = connection.ingestion_batches.where(external_account_id: external.id, stream: "transactions")
      ids = scope.order(:id).limit(MAX_BATCHES + 1).pluck(:id)
      raise TooLarge, "Retained transaction captures exceed the publication bound" if ids.size > MAX_BATCHES
      check_stored_bytes!(scope.where(id: ids))
      scope.where(id: ids).order(:id).lock("FOR SHARE NOWAIT").to_a
    end

    def bounded_generations
      generations = connection.provider_sync_generations.where(stream: "transactions", status: "applied")
      generation_ids = generations.limit(MAX_BATCHES + 1).pluck(:id)
      raise TooLarge, "Retained generation inventory exceeds the publication bound" if generation_ids.size > MAX_BATCHES
      bytes = generations.where(id: generation_ids).sum(Arel.sql("octet_length(context_snapshot)"))
      raise TooLarge, "Retained generation contexts exceed the stored byte bound" if bytes > MAX_BYTES
      generations.where(id: generation_ids).order(:id).to_a
    end

    def check_stored_bytes!(scope)
      bytes = scope.sum(Arel.sql("octet_length(payload)"))
      raise TooLarge, "Retained transaction captures exceed the stored byte bound" if bytes > MAX_BYTES
    end

    def compile(observations, captures)
      by_id = observations.index_by(&:external_id)
      pages = {}
      references = []
      identities = Set.new
      decoded_bytes = 0
      generations = bounded_generations.to_h do |generation|
        Provider::AccountData::GenerationAccountIndex.verify!(generation: generation)
        if generation.context_snapshot.fetch("accounts").key?(external.external_id)
          verify_generation!(generation)
        end
        [ generation.id, generation ]
      end
      ordered_pages = []
      captures.each do |batch|
        generation = generations[batch.provider_sync_generation_id]
        raise Conflict, "Retained capture has no completed generation" unless generation
        verify_generation!(generation)
        binding = generation.context_snapshot.fetch("accounts").fetch(external.external_id)
        unless batch.applied? && batch.origin_kind == "provider" && batch.family_id == @family_id &&
            batch.generation_role == "account" && batch.generation_resource == "transactions" &&
            batch.sync_id == generation.sync_id && batch.writer_epoch == generation.writer_epoch &&
            batch.scope_key == "account:#{external.id}" && batch.source_policy_version.nil? && batch.source_binding == binding
          raise Conflict, "Retained observation has no original applied account capture"
        end
        page = Ingestion::Codec.load(batch.payload)
        serialized = JSON.generate(Ingestion::Codec.dump(page))
        decoded_bytes += serialized.bytesize
        raise TooLarge, "Retained transaction captures exceed the decoded byte bound" if decoded_bytes > MAX_BYTES
        unless page.complete? && batch.complete? && batch.mode == page.mode && batch.coverage == page.coverage.as_json &&
            page.mode == "delta" && page.coverage["pending_absence_authoritative"] == false &&
            page.coverage["removal_policy"] == "exact_external_id" && page.records.all? { |record| record.kind == "transaction" }
          raise Conflict, "Retained capture has unsupported change semantics"
        end
        record_ids = page.records.map { |record| record[:external_id] }
        unless record_ids.uniq.size == record_ids.size && (record_ids & page.removed_ids).empty?
          raise Conflict, "Retained capture has conflicting transaction identities"
        end
        (record_ids + page.removed_ids).each { |id| identities.add(id) }
        raise TooLarge, "Retained transaction identities exceed the publication bound" if identities.size > MAX_RECORDS
        pages[batch.id] = page
        ordered_pages << [ [ generation.writer_epoch, generation.created_at, generation.id, batch.sequence ], batch.id, page ]
        references << { "batch_id" => batch.id, "generation_id" => generation.id, "payload_sha256" => Digest::SHA256.hexdigest(serialized) }
      end
      unless identities == by_id.keys.to_set
        raise Conflict, "Retained transaction observation inventory is incomplete"
      end
      if external.transaction_backfill_required? && identities.empty?
        raise Conflict, "Retained backfill is missing its original transaction changes"
      end
      verify_latest!(observations, ordered_pages)

      records = []
      removed = []
      source_references = observations.map do |row|
        page = pages[row.ingestion_batch_id]
        raise Conflict, "Retained observation does not select an original capture" unless page
        if row.withdrawn?
          unless !row.pending? && page.removed_ids.include?(row.external_id)
            raise Conflict, "Retained withdrawal lacks its exact original tombstone"
          end
          removed << row.external_id
        else
          matching = page.records.select { |record| record[:external_id] == row.input_external_id }
          raise Conflict, "Retained transaction value is missing or ambiguous" unless matching.one?
          record = matching.sole
          metadata = (record[:metadata] || {}).with_indifferent_access
          unless record[:pending] == row.pending? && metadata.fetch(:identity_occurrence, 0) == 0 &&
              metadata.fetch(:observation_order, []) == row.observation_order
            raise Conflict, "Retained transaction state differs from its original capture"
          end
          records << record
        end
        { "source_record_id" => row.id, "batch_id" => row.ingestion_batch_id, "external_id" => row.external_id,
          "pending" => row.pending?, "withdrawn" => row.withdrawn?, "observation_order" => row.observation_order }
      end
      order_pending_relations!(records, by_id)
      Provider::AccountData::Page.new(records: records.sort_by { |record| [ record[:pending] ? 0 : 1, record[:external_id] ] },
        removed_ids: removed.sort, complete: true, mode: "delta",
        coverage: { "retained_replay" => true, "history_complete" => false, "pending_absence_authoritative" => false,
          "removal_policy" => "exact_external_id" },
        evidence: { "retained_transactions" => { "format" => FORMAT, "captures" => references, "observations" => source_references } })
    rescue ArgumentError, KeyError, TypeError
      raise Conflict, "Retained transaction capture is malformed", cause: nil
    end

    def verify_latest!(observations, ordered_pages)
      generation_order = ordered_pages.map { |order, _id, _page| order.first(3) }.uniq
      if generation_order.map { |order| order.first(2) }.uniq.size != generation_order.size
        raise Conflict, "Retained generation order is ambiguous"
      end
      latest = {}
      ordered_pages.sort_by(&:first).each do |_order, batch_id, page|
        page.records.each do |record|
          metadata = (record[:metadata] || {}).with_indifferent_access
          order = metadata.fetch(:observation_order, [])
          previous = latest[record[:external_id]]
          unless order.is_a?(Array) && order.all? { |value| value.is_a?(Integer) } &&
              metadata.fetch(:identity_occurrence, 0) == 0 &&
              (!previous || previous.fetch(:order).empty? || previous.fetch(:order).size == order.size)
            raise Conflict, "Retained observation order is invalid"
          end
          next if previous && previous.fetch(:order).any? && (order <=> previous.fetch(:order)) == -1
          latest[record[:external_id]] = { batch_id: batch_id, pending: record[:pending], withdrawn: false, order: order }
        end
        page.removed_ids.each do |id|
          latest[id] = { batch_id: batch_id, pending: false, withdrawn: true, order: latest[id]&.fetch(:order) || [] }
        end
      end
      observations.each do |row|
        unless latest[row.external_id] == { batch_id: row.ingestion_batch_id, pending: row.pending?, withdrawn: row.withdrawn?, order: row.observation_order }
          raise Conflict, "Retained observation does not identify its latest applied change"
        end
      end
    end

    def verify_generation!(generation)
      unless generation && generation.applied? && generation.stream == "transactions" &&
          generation.family_id == @family_id && generation.provider_connection_id == connection.id &&
          generation.children.count == generation.child_count && generation.pages.count == generation.page_count
        raise Conflict, "Retained observation has no completed transaction generation"
      end
      binding = generation.context_snapshot.fetch("accounts").fetch(external.external_id)
      unless binding["external_account_id"] == external.id && binding["publication"] == "retained" &&
          binding["account_id"].nil? && binding["account_provider_id"].nil? && binding["source_policy_version"].nil?
        raise Conflict, "Retained capture previously had a financial account binding"
      end
      generation
    end

    def order_pending_relations!(records, observations)
      claims = Set.new
      records.each do |record|
        previous_id = record[:pending_external_id]
        next if previous_id.blank? || previous_id == record[:external_id]
        unless !record[:pending] && claims.add?(previous_id)
          raise Conflict, "Retained pending relationship is ambiguous"
        end
        previous = observations[previous_id]
        next unless previous
        unless previous.pending? && !previous.withdrawn?
          raise Conflict, "Retained pending relationship requires explicit reconciliation"
        end
      end
    end
end
