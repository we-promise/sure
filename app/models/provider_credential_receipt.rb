require "digest"

# A confirmed ordinary cookie rotation, committed in the same transaction as
# its credentials. Failed reads may leave receipts, never financial responses.
class ProviderCredentialReceipt < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  MAX_PER_PAGE = 256
  MAX_PER_GENERATION = 32_000
  MAX_EVIDENCE_BYTES = 4_096
  FRAME_KEYS = %w[family_id provider_connection_id provider_sync_generation_id sync_id preceding_batch_id page_sequence request_key prefix_fingerprint].freeze

  encrypted_document :evidence
  belongs_to :family
  belongs_to :provider_connection
  belongs_to :provider_sync_generation
  belongs_to :sync
  belongs_to :preceding_batch, class_name: "IngestionBatch", optional: true
  validates :kind, inclusion: { in: [ "session" ] }
  validates :request_key, :attempt_id, :lease_owner, presence: true
  validates :page_sequence, :ordinal, :from_revision, :to_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :writer_epoch, numericality: { only_integer: true, greater_than: 0 }
  validate :receipt_scope
  before_update { raise Provider::AccountData::StaleWriter, "Credential receipts cannot change" }
  before_destroy { throw :abort }

  def self.scope_for(generation:, page_sequence:, writer_epoch:, lease_owner:)
    frame(generation, page_sequence).merge("writer_epoch" => writer_epoch, "lease_owner" => lease_owner)
  end

  def self.admit!(connection:, scope:, snapshot:)
    generation = live_scope!(connection, scope)
    expected = preceding_snapshot(generation, scope.fetch("page_sequence"))
    ids = recover!(connection: connection, generation: generation, page_sequence: scope.fetch("page_sequence"),
      before: expected, after: snapshot)
    scope.merge("attempt_id" => SecureRandom.uuid, "binding_fingerprint" => binding(snapshot), "recovered_receipt_ids" => ids)
  end

  def self.verify_live_scope!(connection:, scope:)
    live_scope!(connection, scope)
    true
  end

  def self.record!(connection:, scope:, before:, after:, ordinal:, kind:)
    generation = live_scope!(connection, scope)
    unless kind == "session" && binding(before) == scope.fetch("binding_fingerprint") && binding(after) == binding(before) &&
        after.dig("connection", "credential_revision") == before.dig("connection", "credential_revision") + 1 &&
        after.dig("connection", "credential_revision") == connection.credential_revision && ordinal < Provider::AccountData::RequestGrant::MAX_ROTATIONS
      raise Provider::AccountData::StaleWriter, "Credential receipt has no matching session transition"
    end
    if where(provider_sync_generation: generation).limit(MAX_PER_GENERATION + 1).count >= MAX_PER_GENERATION ||
        where(provider_sync_generation: generation, page_sequence: scope.fetch("page_sequence")).limit(MAX_PER_PAGE + 1).count >= MAX_PER_PAGE
      raise Provider::AccountData::StaleWriter, "Credential receipt history exceeds its recovery bound"
    end
    create!(scope.slice(*FRAME_KEYS.excluding("prefix_fingerprint"), "writer_epoch", "lease_owner", "attempt_id").merge(
      "ordinal" => ordinal, "kind" => kind, "from_revision" => before.dig("connection", "credential_revision"),
      "to_revision" => after.dig("connection", "credential_revision"),
      "evidence" => { "version" => 1, "prefix_fingerprint" => scope.fetch("prefix_fingerprint"), "binding_fingerprint" => binding(before) }))
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    raise Provider::AccountData::StaleWriter, "Credential receipt could not be committed", cause: nil
  end

  # Explicit IDs are mandatory for a captured page. Only the still-uncommitted
  # current page may discover its own failed-attempt receipts by revision range.
  def self.recover!(connection:, generation:, page_sequence:, before:, after:, ids: nil)
    from, to = before.dig("connection", "credential_revision"), after.dig("connection", "credential_revision")
    unless from.is_a?(Integer) && to.is_a?(Integer) && to >= from && binding(before) == binding(after) &&
        generation.provider_connection_id == connection.id && generation.family_id == connection.family_id
      raise Provider::AccountData::StaleWriter, "Credential recovery changed its authorization binding"
    end
    if ids.nil? && !(generation.fetching? && generation.page_count == page_sequence)
      raise Provider::AccountData::StaleWriter, "Only the current missing page may recover credential receipts"
    end
    if to - from > MAX_PER_PAGE || (ids && (!ids.is_a?(Array) || ids.size > MAX_PER_PAGE || ids.uniq != ids))
      raise Provider::AccountData::StaleWriter, "Credential recovery exceeds its receipt bound"
    end
    expected = frame(generation, page_sequence)
    rows = where(provider_connection: connection, provider_sync_generation: generation, sync_id: generation.sync_id,
      page_sequence: page_sequence, to_revision: (from + 1)..to).order(:to_revision).limit(MAX_PER_PAGE + 1)
    sizes = rows.pluck(:id, Arel.sql("octet_length(evidence)"))
    unless sizes.size == to - from && sizes.all? { |_id, bytes| bytes.to_i <= MAX_EVIDENCE_BYTES } &&
        (ids.nil? || ids == sizes.map(&:first))
      raise Provider::AccountData::StaleWriter, "Credential recovery has missing or foreign receipts"
    end
    rows.each_with_index do |receipt, index|
      unless receipt.attributes.slice(*FRAME_KEYS.excluding("prefix_fingerprint")) == expected.except("prefix_fingerprint") &&
          receipt.from_revision == from + index && receipt.to_revision == from + index + 1 && receipt.kind == "session" &&
          receipt.evidence == { "version" => 1, "prefix_fingerprint" => expected.fetch("prefix_fingerprint"), "binding_fingerprint" => binding(before) }
        raise Provider::AccountData::StaleWriter, "Credential receipt belongs to another request prefix"
      end
    end
    sizes.map(&:first)
  end

  def self.verify_capture!(connection:, generation:, page_sequence:, expected:, capture:)
    recover!(connection: connection, generation: generation, page_sequence: page_sequence,
      before: expected, after: capture.fetch("before"), ids: capture.fetch("recovered_receipt_ids"))
    recover!(connection: connection, generation: generation, page_sequence: page_sequence,
      before: capture.fetch("before"), after: capture.fetch("after"), ids: capture.fetch("receipt_ids"))
  end

  def self.binding(snapshot)
    raise Provider::AccountData::StaleWriter, "Credential recovery has no request snapshot" unless snapshot.is_a?(Hash) && snapshot["connection"].is_a?(Hash)
    values = snapshot.deep_dup
    values.fetch("connection").delete("credential_revision")
    values.dig("runtime_inputs", "frozen_context")&.delete("clock")
    Provider::AccountData::RuntimeInputs.fingerprint(values, purpose: "provider-credential-receipt-binding/v1")
  end

  def self.frame(generation, index)
    unless index.is_a?(Integer) && index >= 0 && index <= generation.page_count && generation.stream == "activities"
      raise Provider::AccountData::StaleWriter, "Credential receipt has no activity request position"
    end
    previous = index.positive? ? bounded_page(generation, index - 1) : nil
    proof = { "generation_id" => generation.id, "start_cursor" => generation.start_cursor,
      "page_sequence" => index, "preceding_batch_id" => previous&.id, "payload" => previous&.payload }
    { "family_id" => generation.family_id, "provider_connection_id" => generation.provider_connection_id,
      "provider_sync_generation_id" => generation.id, "sync_id" => generation.sync_id,
      "preceding_batch_id" => previous&.id, "page_sequence" => index,
      "request_key" => Digest::SHA256.hexdigest([ generation.id, "page", index ].join(":")),
      "prefix_fingerprint" => Provider::AccountData::RuntimeInputs.fingerprint(proof, purpose: "provider-credential-receipt-prefix/v1") }
  end

  def self.live_scope!(connection, scope)
    unless connection.class.connection.open_transactions.positive? && scope.is_a?(Hash) &&
        scope["lease_owner"].present? && connection.lease_owner == scope["lease_owner"] &&
        connection.writer_epoch == scope["writer_epoch"] && connection.lease_expires_at && connection.lease_expires_at > Time.current &&
        connection.good? && !connection.scheduled_for_deletion?
      raise Provider::AccountData::StaleWriter, "Credential receipt lost its connection lease"
    end
    generation = connection.provider_sync_generations.find_by(id: scope["provider_sync_generation_id"], family_id: connection.family_id, sync_id: scope["sync_id"])
    sync = generation && Sync.find_by(id: generation.sync_id, syncable_type: "ProviderConnection", syncable_id: connection.id)
    unless generation&.fetching? && sync && !sync.cancel_requested_at? && !sync.terminal? &&
        generation.page_count == scope["page_sequence"] && frame(generation, scope["page_sequence"]) == scope.slice(*FRAME_KEYS)
      raise Provider::AccountData::StaleWriter, "Credential receipt request position is no longer current"
    end
    generation
  end

  def self.preceding_snapshot(generation, index)
    return generation.context_snapshot.fetch("request_grant") if index.zero?
    batch = bounded_page(generation, index - 1)
    Ingestion::TransactionGroupCodec.load(batch.payload).evidence.fetch(Provider::AccountData::RequestGrant::EVIDENCE_KEY).fetch("after")
  end

  def self.bounded_page(generation, sequence)
    scope = generation.pages.where(sequence: sequence)
    header = scope.pick(:id, Arel.sql("octet_length(payload)"))
    unless header && header.last.to_i <= Provider::AccountData::TransactionSync::MAX_STORED_BYTES
      raise Provider::AccountData::StaleWriter, "Credential receipt prefix is missing or exceeds its byte bound"
    end
    batch = scope.where(id: header.first).where("octet_length(payload) <= ?", Provider::AccountData::TransactionSync::MAX_STORED_BYTES).first
    unless batch && JSON.generate(batch.payload).bytesize <= Provider::AccountData::TransactionSync::MAX_DECODED_BYTES
      raise Provider::AccountData::StaleWriter, "Credential receipt prefix exceeds its decoded bound"
    end
    batch
  end
  private_class_method :frame, :live_scope!, :preceding_snapshot, :bounded_page

  private
    def receipt_scope
      validate_family_of(provider_connection, :provider_connection)
      validate_connection_of(provider_sync_generation, :provider_sync_generation)
      validate_documents(:evidence)
      unless provider_sync_generation&.stream == "activities" && sync_id == provider_sync_generation&.sync_id && to_revision == from_revision.to_i + 1 && ordinal.to_i < 64
        errors.add(:base, "must describe one credential revision in its original generation")
      end
      unless evidence.is_a?(Hash) && evidence.keys.sort == %w[binding_fingerprint prefix_fingerprint version] && evidence["version"] == 1 &&
          %w[binding_fingerprint prefix_fingerprint].all? { |key| evidence[key].is_a?(String) && evidence[key].match?(/\A[0-9a-f]{64}\z/) }
        errors.add(:evidence, "must contain the original binding and prefix fingerprints")
      end
      return unless page_sequence.is_a?(Integer)
      valid_prefix = if page_sequence.to_i.zero?
        preceding_batch_id.nil?
      else
        preceding_batch && preceding_batch.provider_sync_generation_id == provider_sync_generation_id &&
          preceding_batch.provider_connection_id == provider_connection_id && preceding_batch.family_id == family_id &&
          preceding_batch.sync_id == sync_id && preceding_batch.sequence == page_sequence - 1 &&
          preceding_batch.generation_role == "page" && preceding_batch.stream == "activity_groups"
      end
      errors.add(:preceding_batch, "must be the preceding page in this generation") unless valid_prefix
    end
end
