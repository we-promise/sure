# frozen_string_literal: true

class DirectaItem
  class Login
    CHALLENGE_TTL = 5.minutes
    OTP_SUBMISSION_TTL = 30.seconds
    MAX_OTP_ATTEMPTS = 3
    ACCOUNT_NUMBER_PATTERN = /\A[0-9]{1,32}\z/
    OTP_CODE_PATTERN = /\A[0-9]{1,12}\z/
    LOGIN_ERROR_CODES = %w[
      account_conflict account_identity_changed account_mismatch attempts_exhausted
      authentication_failed challenge_expired challenge_not_available encryption_unavailable
      invalid_account invalid_code invalid_credentials login_authorization_changed
      login_in_progress provider_unavailable rate_limited
    ].freeze

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end

    def initialize(item, provider: nil, clock: -> { Time.current })
      @item = item
      @provider = provider
      @clock = clock
    end

    def start(broker_account:, password:, session_id:)
      ensure_encryption!
      account_number = normalize_account!(broker_account)
      secret = password.to_s.dup
      raise Error.new(:invalid_credentials) if secret.blank? || secret.bytesize > 512
      ensure_persisted!

      failure = nil
      result = nil

      @item.with_lock do
        expire_pending_if_needed!
        if pending_state
          failure = Error.new(:login_in_progress)
          next
        end

        attempt_id = SecureRandom.urlsafe_base64(24)
        generation = @item.connection_generation + 1
        state = pending_context(
          account_number: account_number,
          session_id: session_id,
          generation: generation,
          attempt_id: attempt_id,
          stage: "starting"
        )

        begin
          ensure_authorized_owner!(state) { }
          ensure_same_account!(account_number)
          @item.update!(pending_login_state: encode(state), status: connected_session? ? :connected : :pending)

          response = provider.begin_login(
            account_number: account_number,
            password: secret,
            connection_generation: generation
          )
          result = apply_start_response!(response, state)
        rescue Provider::Directa::Error => error
          clear_pending_state!
          failure = sanitized_error(error)
        rescue Error => error
          clear_pending_state!
          failure = error
        rescue StandardError
          clear_pending_state!
          failure = Error.new(:provider_unavailable)
        end
      end

      raise failure if failure

      result
    ensure
      secret&.clear
    end

    def complete(otp_code:, attempt_id:, session_id:)
      ensure_encryption!
      code = otp_code.to_s.strip
      raise Error.new(:invalid_code) unless OTP_CODE_PATTERN.match?(code)

      failure = nil
      reservation = nil

      @item.with_lock do
        state = pending_state
        if state.blank? || !state_matches?(state, attempt_id: attempt_id, session_id: session_id)
          failure = Error.new(:challenge_not_available)
          next
        end

        if state["stage"] == "otp_submitting"
          if submission_expired?(state)
            clear_pending_state!
            failure = Error.new(:challenge_expired)
          else
            failure = Error.new(:login_in_progress)
          end
          next
        end

        if state["stage"] != "otp_required"
          failure = Error.new(:challenge_not_available)
          next
        end

        if expired?(state)
          clear_pending_state!
          failure = Error.new(:challenge_expired)
          next
        end

        if state.fetch("attempts", 0).to_i >= MAX_OTP_ATTEMPTS
          clear_pending_state!
          failure = Error.new(:attempts_exhausted)
          next
        end

        begin
          ensure_authorized_owner!(state) { }
          state["attempts"] = state.fetch("attempts", 0).to_i + 1
          state["stage"] = "otp_submitting"
          state["submission_started_at"] = @clock.call.utc.iso8601(6)
          @item.update!(pending_login_state: encode(state))
          reservation = state.deep_dup
        rescue Error => error
          clear_pending_state!
          failure = error
        end
      end

      raise failure if failure
      return :challenge_not_available unless reservation

      response = nil
      provider_failure = nil
      begin
        response = provider.complete_login(
          account_number: reservation.fetch("account_number"),
          challenge_token: reservation.fetch("challenge_token"),
          otp_code: code,
          connection_generation: reservation.fetch("connection_generation")
        )
      rescue Provider::Directa::Error => error
        provider_failure = sanitized_error(error)
      rescue StandardError
        provider_failure = Error.new(:provider_unavailable)
      end

      outcome = nil
      @item.with_lock do
        state = pending_state
        unless reserved_state_matches?(state, reservation)
          failure = Error.new(:challenge_not_available)
          next
        end

        if expired?(state)
          clear_pending_state!
          failure = Error.new(:challenge_expired)
          next
        end

        if provider_failure
          clear_pending_state!
          failure = provider_failure
          next
        end

        begin
          if response.is_a?(Provider::Directa::LoginChallenge)
            verify_challenge!(response, state)
            if state.fetch("attempts").to_i >= MAX_OTP_ATTEMPTS
              clear_pending_state!
              outcome = :attempts_exhausted
            else
              ensure_authorized_owner!(state) do
                state["challenge_token"] = response.challenge_token
                state["stage"] = "otp_required"
                state.delete("submission_started_at")
                @item.update!(pending_login_state: encode(state))
              end
              outcome = :otp_required
            end
          elsif response.is_a?(Provider::Directa::VerifiedSession)
            apply_verified_session!(response, state)
            outcome = :authenticated
          else
            clear_pending_state!
            failure = Error.new(:provider_unavailable)
          end
        rescue Provider::Directa::Error => error
          clear_pending_state!
          failure = sanitized_error(error)
        rescue Error => error
          clear_pending_state!
          failure = error
        rescue StandardError
          clear_pending_state!
          failure = Error.new(:provider_unavailable)
        end
      end

      raise failure if failure

      outcome
    ensure
      code&.clear
    end

    def cancel(attempt_id:, session_id:)
      @item.with_lock do
        state = pending_state
        next false unless state && state_matches?(state, attempt_id: attempt_id, session_id: session_id)

        clear_pending_state!
        true
      end
    end

    def summary(session_id:)
      return unless @item.persisted?

      @item.with_lock do
        state = pending_state
        next unless state

        if expired?(state) || submission_expired?(state)
          clear_pending_state!
          next
        end
        next unless state_matches_identity?(state, session_id: session_id)

        if state["stage"] == "otp_submitting"
          { stage: "otp_submitting" }
        elsif state["stage"] == "otp_required"
          {
            stage: "otp_required",
            attempt_id: state.fetch("attempt_id"),
            attempts_remaining: [ MAX_OTP_ATTEMPTS - state.fetch("attempts", 0).to_i, 0 ].max,
            expires_at: Time.iso8601(state.fetch("expires_at")).utc.iso8601
          }
        end
      end
    rescue ArgumentError, KeyError, TypeError
      clear_pending_if_malformed!
      nil
    end

    private

      def provider
        @provider ||= Provider::Directa.new
      end

      def ensure_encryption!
        raise Error.new(:encryption_unavailable) unless ActiveRecordEncryptionConfig.explicitly_configured?
      end

      def ensure_persisted!
        return if @item.persisted?

        @item.save!
      rescue ActiveRecord::RecordNotUnique
        raise Error.new(:login_in_progress), cause: nil
      end

      def normalize_account!(value)
        account_number = value.to_s.strip
        raise Error.new(:invalid_account) unless ACCOUNT_NUMBER_PATTERN.match?(account_number)

        account_number.rjust(5, "0")
      end

      def ensure_same_account!(account_number)
        return if @item.broker_account.blank?
        return if secure_equal?(@item.broker_account, account_number)

        raise Error.new(:account_identity_changed)
      end

      def pending_context(account_number:, session_id:, generation:, attempt_id:, stage:)
        {
          "account_number" => account_number,
          "attempt_id" => attempt_id,
          "attempts" => 0,
          "connection_generation" => generation,
          "expires_at" => (@clock.call + CHALLENGE_TTL).utc.iso8601(6),
          "family_id" => @item.family_id.to_s,
          "owner_id" => @item.owner_id.to_s,
          "session_id" => session_id.to_s,
          "stage" => stage
        }
      end

      def apply_start_response!(response, state)
        if response.is_a?(Provider::Directa::LoginChallenge)
          verify_challenge!(response, state)
          ensure_authorized_owner!(state) do
            state["challenge_token"] = response.challenge_token
            state["stage"] = "otp_required"
            state["expires_at"] = (@clock.call + CHALLENGE_TTL).utc.iso8601(6)
            @item.update!(pending_login_state: encode(state), status: connected_session? ? :connected : :pending)
          end
          :otp_required
        elsif response.is_a?(Provider::Directa::VerifiedSession)
          apply_verified_session!(response, state)
          :authenticated
        else
          raise Error.new(:provider_unavailable)
        end
      end

      def verify_challenge!(response, state)
        unless response.account_number.to_s == state.fetch("account_number") &&
            response.connection_generation.to_i == state.fetch("connection_generation").to_i &&
            response.challenge_token.to_s.present?
          raise Error.new(:authentication_failed)
        end
      end

      def apply_verified_session!(response, state)
        expected_generation = state.fetch("connection_generation").to_i
        unless response.is_a?(Provider::Directa::VerifiedSession) &&
            response.account_number.to_s == state.fetch("account_number") &&
            response.connection_generation.to_i == expected_generation &&
            response.account_identity.to_s.present? && response.multi_token.to_s.present? &&
            response.mono_token.to_s.present? && response.host.to_s == Provider::Directa::HOST
          raise Error.new(:authentication_failed)
        end

        if @item.connection_generation.to_i + 1 != expected_generation
          raise Error.new(:login_authorization_changed)
        end
        if @item.account_identity.present? && @item.account_identity != response.account_identity.to_s
          raise Error.new(:account_identity_changed)
        end

        ensure_authorized_owner!(state) do
          @item.update!(
            broker_account: state.fetch("account_number"),
            account_identity: response.account_identity.to_s,
            multi_token: response.multi_token.to_s,
            mono_token: response.mono_token.to_s,
            connection_generation: expected_generation,
            pending_login_state: nil,
            status: :connected,
            last_sync_error_code: @item.portfolio_snapshot_at.blank? ? "awaiting_valuation" : nil
          )
        end
      end

      def ensure_authorized_owner!(state)
        owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
        raise Error.new(:login_authorization_changed) unless owner

        owner.with_lock do
          current_owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
          session = Session.lock.find_by(id: state["session_id"], user_id: current_owner&.id)
          authorized = current_owner&.active? && current_owner.admin? &&
            current_owner.preview_features_enabled? && current_owner.family.can_connect_directa? &&
            session.present? && session.active_impersonator_session_id.blank?
          raise Error.new(:login_authorization_changed) unless authorized

          yield if block_given?
        end
      end

      def reserved_state_matches?(state, reservation)
        state.present? && state["stage"] == "otp_submitting" &&
          state["attempts"].to_i == reservation["attempts"].to_i &&
          state["connection_generation"].to_i == reservation["connection_generation"].to_i &&
          state_matches?(state, attempt_id: reservation["attempt_id"], session_id: reservation["session_id"])
      end

      def state_matches?(state, attempt_id:, session_id:)
        state_matches_identity?(state, session_id: session_id) && secure_equal?(state["attempt_id"], attempt_id.to_s)
      end

      def state_matches_identity?(state, session_id:)
        state["session_id"].to_s == session_id.to_s &&
          state["owner_id"].to_s == @item.owner_id.to_s &&
          state["family_id"].to_s == @item.family_id.to_s
      end

      def secure_equal?(left, right)
        return false if left.blank? || right.blank? || left.bytesize != right.bytesize

        ActiveSupport::SecurityUtils.secure_compare(left, right)
      end

      def pending_state
        return unless @item.pending_login_state.present?

        parsed = JSON.parse(@item.pending_login_state)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError, TypeError
        nil
      end

      def encode(state)
        JSON.generate(state)
      end

      def expire_pending_if_needed!
        return unless (state = pending_state)
        return unless expired?(state) || submission_expired?(state)

        clear_pending_state!
      end

      def expired?(state)
        Time.iso8601(state.fetch("expires_at")) <= @clock.call
      rescue KeyError, ArgumentError, TypeError
        true
      end

      def submission_expired?(state)
        return false unless state["stage"] == "otp_submitting"

        Time.iso8601(state.fetch("submission_started_at")) + OTP_SUBMISSION_TTL <= @clock.call
      rescue KeyError, ArgumentError, TypeError
        true
      end

      def connected_session?
        @item.session_configured?
      end

      def clear_pending_state!
        @item.update!(
          pending_login_state: nil,
          status: connected_session? ? :connected : :requires_update
        )
      end

      def clear_pending_if_malformed!
        @item.with_lock { clear_pending_state! }
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def sanitized_error(error)
        code = error.respond_to?(:failure_code) ? error.failure_code.to_s : "authentication_failed"
        safe_code = LOGIN_ERROR_CODES.include?(code) ? code : "authentication_failed"
        Error.new(safe_code)
      end
  end
end
