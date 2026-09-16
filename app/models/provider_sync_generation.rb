# A connection cursor is promoted only after every sealed account batch commits.
# Fetching/abandoned pages remain encrypted evidence and never reach the ledger.
class ProviderSyncGeneration < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypts :start_cursor, :terminal_cursor
  encrypted_document :context_snapshot

  belongs_to :family
  belongs_to :provider_connection
  belongs_to :sync
  has_many :ingestion_batches, dependent: :restrict_with_error
  has_many :provider_sync_checkpoints, dependent: :restrict_with_error
  has_many :pages, -> { where(generation_role: "page").order(:sequence) }, class_name: "IngestionBatch"
  has_many :children, -> { where(generation_role: "account").order(:sequence) }, class_name: "IngestionBatch"

  enum :status, { fetching: "fetching", sealed: "sealed", applied: "applied", abandoned: "abandoned" }, default: :fetching, validate: true
  scope :unfinished, -> { where(status: %w[fetching sealed]) }

  CAPTURED_ATTRIBUTES = %w[family_id provider_connection_id sync_id provider_sync_type stream scope_key start_cursor context_snapshot writer_epoch].freeze
  before_validation -> { self.family_id ||= provider_connection&.family_id }
  validates :stream, inclusion: { in: %w[transactions activities] }
  validates :scope_key, inclusion: { in: [ "connection" ] }
  validates :writer_epoch, :page_count, :child_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :transport_retry_count, numericality: { only_integer: true, in: 0..16 }
  validate :ownership_and_state
  validate :immutable_capture
  validate :account_projection_matches_capture

  private
    def ownership_and_state
      validate_family_of(provider_connection, :provider_connection)
      validate_documents(:context_snapshot)
      errors.add(:transport_retry_count, "requires an activity generation") if stream != "activities" && transport_retry_count != 0
      unless sync&.syncable_type == "ProviderConnection" && sync.syncable_id == provider_connection_id
        errors.add(:sync, "must belong to this connection")
      end
      if sealed? || applied?
        errors.add(:terminal_cursor, "is required for a sealed generation") if terminal_cursor.blank?
        errors.add(:sealed_at, "is required") unless sealed_at
        errors.add(:page_count, "must include a terminal page") unless page_count.to_i.positive?
      end
      errors.add(:applied_at, "must match the applied status") if applied? != applied_at.present?
    end

    def immutable_capture
      return if new_record?
      CAPTURED_ATTRIBUTES.each do |attribute|
        errors.add(attribute, "is captured evidence and cannot change") if will_save_change_to_attribute?(attribute)
      end
      if will_save_change_to_transport_retry_count? &&
          (status_in_database != "fetching" || transport_retry_count != transport_retry_count_in_database + 1)
        errors.add(:transport_retry_count, "must advance once while fetching")
      end
      if status_in_database != "fetching"
        %w[terminal_cursor page_count child_count sealed_at].each do |attribute|
          errors.add(attribute, "belongs to a sealed generation") if will_save_change_to_attribute?(attribute)
        end
      end
      return unless will_save_change_to_status?
      transitions = { "fetching" => %w[sealed abandoned], "sealed" => [ "applied" ], "applied" => [], "abandoned" => [] }
      errors.add(:status, "cannot discard or reopen a generation") unless transitions.fetch(status_in_database).include?(status)
    end

    def account_projection_matches_capture
      return unless new_record? || will_save_change_to_account_ids?
      if persisted? && !account_ids_in_database.nil? && will_save_change_to_account_ids?
        errors.add(:account_ids, "is captured evidence and cannot change")
        return
      end
      return if account_ids.nil?
      expected = Provider::AccountData::GenerationAccountIndex.capture_ids(context_snapshot: context_snapshot, stream: stream)
      errors.add(:account_ids, "must match the original account capture") unless account_ids == expected
    rescue Provider::AccountData::GenerationAccountIndex::Conflict
      errors.add(:account_ids, "requires a valid original account capture")
    end
end
