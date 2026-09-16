# Single-use refresh tokens need a committed intent before the HTTP exchange.
# A PostgreSQL session lock serializes callers without holding a row transaction
# over the network. An abandoned intent requires reauthorization; it is never
# treated as permission to reuse a possibly consumed refresh token.
class Provider::AccountData::CredentialStore
  class Busy < Provider::AccountData::IncompletePage; end
  class ReauthorizationRequired < Provider::AccountData::Error; end
  LOCK_CONTEXT = :provider_credential_connection_lock

  def initialize(connection:, request_grant: nil)
    request_grant&.assert_connection!(connection)
    @connection_id = connection.id.to_s.dup.freeze
    @family_id = connection.family_id.to_s.dup.freeze
    @request_grant = request_grant
  end

  def with_session_lock
    self.class.with_connection_lock(connection_id: @connection_id) do
      session = nil
      begin
        connection = ProviderConnection.where(family_id: @family_id).find(@connection_id)
        session = Session.new(connection, request_grant: @request_grant)
        yield session
      ensure
        session&.close!
      end
    end
  end

  # Administrative replacement uses the same lock without constructing a refresh
  # Session: merely opening an editor must not mutate an unfinished exchange.
  def self.with_connection_lock(connection_id:)
    unless connection_id.is_a?(String) && connection_id.match?(Provider::AccountData::LegacyWriterFence::UUID)
      raise ArgumentError, "Credential lock requires a connection identity"
    end
    ProviderConnection.connection_pool.with_connection do |database|
      unless database.open_transactions.zero?
        raise ArgumentError, "Credential operations must run outside a database transaction"
      end
      raise Busy, "Credential operations cannot be nested" if ActiveSupport::IsolatedExecutionState[LOCK_CONTEXT]
      key = database.quote("provider_credentials:#{connection_id}")
      lock = "hashtextextended(#{key}, 0)"
      acquired, acquiring, failure = false, false, nil
      begin
        acquiring = true
        acquired = database.select_value("SELECT pg_try_advisory_lock(#{lock})")
        acquiring = false
        raise Busy, "Another credential operation is running" unless acquired
        ActiveSupport::IsolatedExecutionState[LOCK_CONTEXT] = connection_id.dup.freeze
        yield
      rescue Exception => error # rubocop:disable Lint/RescueException -- release on interruption as well
        failure = error
        raise
      ensure
        ActiveSupport::IsolatedExecutionState.delete(LOCK_CONTEXT)
        begin
          raise Busy, "Credential lock acquisition is uncertain" if acquiring
          if acquired && !database.select_value("SELECT pg_advisory_unlock(#{lock})")
            raise Busy, "Credential lock ownership was lost"
          end
        rescue StandardError => release_error
          begin
            database.disconnect!
          rescue StandardError
            # Do not replace the original operation or release failure.
          end
          raise release_error unless failure
        end
      end
    end
  end

  class Session
    def initialize(connection, request_grant: nil)
      @connection = connection
      @request_grant = request_grant
      @revision = connection.credential_revision
      @closed = false
      verify_ownership!
      if @connection.credential_state.present? && @connection.good?
        # Acquiring the grant lock with an unfinished intent means the previous
        # owner released it without committing a usable replacement token.
        mutate! do
          @connection.credential_state = @connection.credential_state.merge("status" => "uncertain")
          @connection.status = "requires_update"
        end
      end
    end

    def credentials
      ensure_open!
      @connection.reload
      verify_ownership!
      raise ReauthorizationRequired, "Connection needs reauthorization" unless @connection.good?
      @connection.credentials.deep_dup
    end

    def refresh_pending?
      ensure_open!
      verify_ownership!
      @connection.credential_state.present?
    end

    def begin_refresh!
      mutate! do
        raise ReauthorizationRequired, "Previous credential exchange needs reauthorization" if refresh_pending?
        unless @connection.good?
          raise ReauthorizationRequired, "Connection needs reauthorization"
        end
        @attempt_id = SecureRandom.uuid
        @connection.credential_state = {
          "status" => "refreshing", "attempt_id" => @attempt_id, "started_at" => Time.current.iso8601(9)
        }
      end
    end

    def persist_credentials!(values)
      validate_credentials!(values)
      mutate!(rotation: "refresh") do
        verify_attempt!
        raise Provider::AccountData::StaleWriter, "Connection authorization changed" unless @connection.good?
        @connection.credentials = values.deep_dup
        @connection.credential_state = {}
        @connection.credential_revision += 1
      end
      @revision = @connection.credential_revision
      @attempt_id = nil
    end

    # Ordinary session cookies can change on a successful read without consuming
    # the previous credentials. Persist the confirmed jar before exposing data,
    # without inventing single-use refresh intent for harmless read failures.
    def persist_session_credentials!(values)
      validate_credentials!(values)
      mutate!(rotation: "session") do
        unless @connection.good? && @connection.credential_state.empty?
          raise ReauthorizationRequired, "Session credentials cannot replace an unfinished token exchange"
        end
        if @connection.credentials != values
          @connection.credentials = values.deep_dup
          @connection.credential_revision += 1
        end
      end
      @revision = @connection.credential_revision
    end

    def mark_refresh_uncertain!
      mutate! do
        verify_attempt!
        @connection.credential_state = @connection.credential_state.merge("status" => "uncertain")
        @connection.status = "requires_update"
      end
    end

    def close!
      @closed = true
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private
      def validate_credentials!(values)
        unless values.is_a?(Hash) && values.present? && values.keys.all? { |key| key.is_a?(String) }
          raise ArgumentError, "Replacement credentials must be a nonempty string-keyed object"
        end
      end

      def ensure_open!
        raise Provider::AccountData::StaleWriter, "Credential session is closed" if @closed
      end

      def mutate!(rotation: nil)
        ensure_open!
        unless ProviderConnection.connection.open_transactions.zero?
          raise ArgumentError, "Credential state must commit outside an enclosing transaction"
        end
        @connection.with_lock do
          verify_ownership!
          yield
          @connection.save!
          if rotation && @connection.credential_revision != @revision
            @request_grant&.accept_credential_rotation!(from_revision: @revision, kind: rotation)
          end
        end
      rescue StandardError
        # A failed outer commit may leave the in-memory grant ahead of the
        # database even though cookie and receipt rolled back together. That
        # request must not lend its speculative revision to another read.
        if @request_grant && @request_grant.snapshot&.dig("connection", "credential_revision") != @revision
          @request_grant.invalidate!
        end
        raise
      end

      def verify_ownership!
        @request_grant&.verify_credential_access!
        if @connection.credential_revision != @revision || @connection.scheduled_for_deletion? || @connection.disabled?
          raise Provider::AccountData::StaleWriter, "Credential ownership changed"
        end
        control = ProviderMigrationControl.find_by(provider_connection_id: @connection.id)
        if control && !control.native_owned?
          raise Provider::AccountData::StaleWriter, "Legacy connection still owns credentials"
        end
      end

      def verify_attempt!
        unless @attempt_id && @connection.credential_state["attempt_id"] == @attempt_id
          raise Provider::AccountData::StaleWriter, "Credential exchange intent changed"
        end
      end
  end
  private_constant :Session
end
