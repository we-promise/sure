require "digest"

# Durable intent/result for a single-use credential exchange. The caller owns
# remote I/O and target installation; this journal never infers remote success.
class ProviderCredentialClaim < ApplicationRecord
  include ProviderDataEncryption

  class Busy < Provider::AccountData::IncompletePage; end
  class Pending < Provider::AccountData::IncompletePage; end

  MAX_DOCUMENT_BYTES = 32.kilobytes
  MAX_STORED_BYTES = 64.kilobytes
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  FINGERPRINT = /\A[0-9a-f]{64}\z/
  IMMUTABLE_ATTRIBUTES = %w[family_id provider_key operation target_type target_id request_fingerprint request expected].freeze
  CANCELLABLE_STATES = %w[prepared claiming claimed uncertain].freeze
  CANCELLATION_ATTRIBUTES = %w[cancelled_at cancelled_by_id cancelled_from_state cancellation_reason].freeze
  TRANSITIONS = {
    "prepared" => %w[claiming cancelled], "claiming" => %w[claimed uncertain cancelled],
    "claimed" => %w[installed cancelled], "installed" => [], "uncertain" => %w[cancelled], "cancelled" => []
  }.freeze
  LOCK_CONTEXT = :provider_credential_claim_locks
  LOCK_NAMESPACE = "sure:provider-credential-claim:v1".freeze

  encrypted_document :request, :expected, :response
  belongs_to :family
  enum :state, TRANSITIONS.keys.index_with(&:itself), default: "prepared", validate: true

  validates :provider_key, inclusion: { in: %w[simplefin] }
  validates :target_type, inclusion: { in: %w[SimplefinItem] }
  validates :operation, inclusion: { in: %w[connect reconnect] }
  validates :target_id, format: { with: UUID }
  validates :request_fingerprint, format: { with: FINGERPRINT }, uniqueness: { scope: :provider_key }
  validates :sync_id, format: { with: UUID }, allow_nil: true
  validates :cancelled_by_id, format: { with: UUID }, allow_nil: true
  validates :installed_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :bounded_documents
  validate :document_shapes
  validate :cancellation_shape
  validate :valid_transition
  validate :immutable_capture

  def inspect
    "#<#{self.class.name} id=#{id.inspect} state=#{state.inspect}>"
  end

  class << self
    # Only an exclusive legacy permit makes this absence check stable against
    # claim preparation/execution. Terminal ambiguity is retained, not repaired.
    def assert_settled_for!(item)
      current = Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
      pending = uncached do
        where(target_type: current.class.base_class.name, target_id: current.id,
          state: %w[prepared claiming claimed]).exists?
      end
      if pending
        raise Pending, "Finish or explicitly resolve outstanding credential claims before migration preparation"
      end
      true
    end

    def with_target_lock(target_type:, target_id:, &block)
      unless target_type == "SimplefinItem" && target_id.is_a?(String) && target_id.match?(UUID)
        raise ArgumentError, "Unsupported credential claim target"
      end
      with_session_lock(:target, [ target_type, target_id.downcase ], &block)
    end

    def with_request_lock(provider_key:, request_fingerprint:, &block)
      unless provider_key == "simplefin" && request_fingerprint.is_a?(String) && request_fingerprint.match?(FINGERPRINT)
        raise ArgumentError, "Invalid credential claim request"
      end
      with_session_lock(:request, [ provider_key, request_fingerprint ], &block)
    end

    private
      def with_session_lock(kind, identity)
        connection_pool.with_connection do |database|
          held = ActiveSupport::IsolatedExecutionState[LOCK_CONTEXT]
          if held
            raise ArgumentError, "Credential claim locks belong to another database session" unless held[:database].equal?(database)
            if held[kind]
              raise ArgumentError, "Credential claim locks cannot be widened" unless held[kind] == identity
              return yield
            end
          end
          if kind == :request && !held&.dig(:target)
            raise ArgumentError, "Acquire the credential target before its request"
          end
          unless database.open_transactions.zero?
            raise ArgumentError, "Acquire credential claim locks before a database transaction"
          end

          key = Digest::SHA256.digest([ LOCK_NAMESPACE, kind.to_s, *identity ].join("\0")).unpack1("q>")
          acquired = false
          acquiring = false
          failure = nil
          begin
            acquiring = true
            acquired = database.select_value("SELECT pg_try_advisory_lock(#{key})")
            acquiring = false
            raise Busy, "Another credential claim is running" unless acquired
            context = (held || { database: database }).merge(kind => identity.map { |value| value.dup.freeze }.freeze).freeze
            ActiveSupport::IsolatedExecutionState[LOCK_CONTEXT] = context
            yield
          rescue Exception => error # Always release the session lock, including interrupted callers.
            failure = error
            raise
          ensure
            ActiveSupport::IsolatedExecutionState[LOCK_CONTEXT] = held
            begin
              if acquiring
                # The server may have acquired a lock before a lost response or
                # interruption. Closing this session releases any such lock.
                database.disconnect!
              elsif acquired && !database.select_value("SELECT pg_advisory_unlock(#{key})")
                raise Busy, "Credential claim lock was lost"
              end
            rescue StandardError
              # Do not return a pooled connection with uncertain lock ownership.
              begin
                database.disconnect!
              rescue StandardError
                # Preserve the original operation or unlock failure.
              end
              raise unless failure
            end
          end
        end
      end
  end

  private
    def bounded_documents
      %i[request expected response].each do |attribute|
        value = public_send(attribute)
        unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
          errors.add(attribute, "must be a string-keyed object")
          next
        end
        errors.add(attribute, "exceeds the credential claim byte bound") if JSON.generate(value).bytesize > MAX_DOCUMENT_BYTES
      rescue JSON::GeneratorError, ArgumentError, EncodingError, SystemStackError
        errors.add(attribute, "must contain bounded JSON values")
      end
    end

    def document_shapes
      unless request.is_a?(Hash) && request.keys.all? { |key| key.is_a?(String) } && request.keys.sort == %w[item_name setup_token] &&
          request["setup_token"].is_a?(String) && request["setup_token"].present? &&
          (request["item_name"].nil? || request["item_name"].is_a?(String))
        errors.add(:request, "must contain the setup token and optional item name")
      end
      unless expected.is_a?(Hash) && expected.keys.all? { |key| key.is_a?(String) } && expected.keys.sort == %w[credential_revision family_id item_id writer_epoch] &&
          expected["family_id"] == family_id && expected["item_id"] == target_id &&
          expected["writer_epoch"].is_a?(Integer) && expected["writer_epoch"] >= 0 &&
          ((operation == "connect" && expected["credential_revision"].nil?) ||
            (operation == "reconnect" && expected["credential_revision"].is_a?(Integer) && expected["credential_revision"] >= 0))
        errors.add(:expected, "must describe the original target and credential revision")
      end
      if claimed? || installed? || (cancelled? && cancelled_from_state == "claimed")
        unless response.is_a?(Hash) && response.keys == [ "access_url" ] && response["access_url"].is_a?(String) && response["access_url"].present?
          errors.add(:response, "must contain the confirmed access URL")
        end
      elsif response != {}
        errors.add(:response, "requires a confirmed claim")
      end
      if installed?
        errors.add(:installed_revision, "is required after installation") if installed_revision.nil?
      elsif installed_revision || sync_id
        errors.add(:base, "Installation metadata requires an installed claim")
      end
    end

    def cancellation_shape
      unless cancelled?
        errors.add(:base, "Cancellation metadata requires a cancelled claim") if CANCELLATION_ATTRIBUTES.any? { |attribute| !public_send(attribute).nil? }
        return
      end

      unless cancelled_at.is_a?(Time) || cancelled_at.is_a?(DateTime)
        errors.add(:cancelled_at, "must record the cancellation time")
      end
      errors.add(:cancelled_by_id, "must identify the cancelling actor") if cancelled_by_id.nil?
      unless CANCELLABLE_STATES.include?(cancelled_from_state)
        errors.add(:cancelled_from_state, "must identify the previous claim state")
      end
      unless cancellation_reason == "user_cancelled"
        errors.add(:cancellation_reason, "must identify an explicit cancellation")
      end
      if persisted? && will_save_change_to_state? && cancelled_from_state != state_in_database
        errors.add(:cancelled_from_state, "must match the previous claim state")
      end
    end

    def immutable_capture
      return if new_record?
      IMMUTABLE_ATTRIBUTES.each do |attribute|
        errors.add(attribute, "cannot change after preparation") if will_save_change_to_attribute?(attribute)
      end
      # Rails treats a serialized {} backed by SQL NULL as changed in place.
      # Compare decoded values so a state-only save may retain that empty result.
      if response != response_in_database && !(state_in_database == "claiming" && state == "claimed")
        errors.add(:response, "cannot change outside claim confirmation")
      end
      if will_save_change_to_installed_revision? && !(state_in_database == "claimed" && installed?)
        errors.add(:installed_revision, "cannot change outside installation")
      end
      if will_save_change_to_sync_id? && !(sync_id_in_database.nil? && installed? && %w[claimed installed].include?(state_in_database))
        errors.add(:sync_id, "cannot replace the original installation Sync")
      end
      unless cancelled? && CANCELLABLE_STATES.include?(state_in_database)
        CANCELLATION_ATTRIBUTES.each do |attribute|
          errors.add(attribute, "cannot change outside cancellation") if will_save_change_to_attribute?(attribute)
        end
      end
    end

    def valid_transition
      if new_record?
        errors.add(:state, "must begin prepared") unless prepared?
      elsif will_save_change_to_state? && !TRANSITIONS.fetch(state_in_database, []).include?(state)
        errors.add(:state, "cannot replay a consumed or ambiguous claim")
      end
    end
end
