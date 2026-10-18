class CaAutoBankItem::Login
  CHALLENGE_TTL = 5.minutes
  POLL_INTERVAL = 10.seconds
  MAX_POLLS = 30
  ERROR_CODES = %w[
    invalid_credentials authentication_failed unsupported_login invalid_session session_expired
    provider_unavailable rate_limited encryption_unavailable login_in_progress challenge_expired
    challenge_not_available login_authorization_changed account_identity_changed
  ].freeze

  def initialize(item, provider: nil)
    @item = item
    @provider = provider
  end

  def start(email:, password:, session_id:)
    ensure_encryption!
    email_address = email.to_s.strip
    secret = password.to_s.dup
    fail!(:invalid_credentials) unless URI::MailTo::EMAIL_REGEXP.match?(email_address) && email_address.bytesize <= 254 && secret.present? && secret.bytesize <= 512
    @item.save! unless @item.persisted?

    result = nil
    failure = nil
    authorize!(session_id) do
      @item.with_lock do
        begin
          state = read_state
          fail!(:login_in_progress) if state && !expired?(state)
          client = @provider || Provider::CaAutoBank.new
          state = {
            "attempt_id" => SecureRandom.urlsafe_base64(24), "session_id" => session_id.to_s,
            "owner_id" => @item.owner_id, "family_id" => @item.family_id,
            "generation" => @item.connection_generation, "polls" => 0,
            "request_session_id" => client.request_session_id,
            "expires_at" => CHALLENGE_TTL.from_now.utc.iso8601
          }
          response = client.begin_login(email: email_address, password: secret)
          result = apply_response!(response, state)
        rescue Provider::CaAutoBank::Error => error
          clear_pending! unless error.code == "login_in_progress"
          failure = safe_error(error)
        end
      end
    end
    raise failure if failure

    result
  rescue ActiveRecord::RecordNotUnique
    fail!(:login_in_progress)
  ensure
    secret&.clear
  end

  def poll(attempt_id:, session_id:)
    ensure_encryption!
    result = nil
    failure = nil
    authorize!(session_id) do
      @item.with_lock do
        begin
          state = read_state
          fail!(:challenge_not_available) unless matches?(state, attempt_id: attempt_id, session_id: session_id)
          fail!(:challenge_expired) if expired?(state) || state.fetch("polls", 0) >= MAX_POLLS
          last_poll = Time.iso8601(state["last_poll_at"]) if state["last_poll_at"]
          if last_poll && last_poll + POLL_INTERVAL > Time.current
            result = :pending
            next
          end
          state["polls"] = state.fetch("polls", 0) + 1
          state["last_poll_at"] = Time.current.utc.iso8601(6)
          client = @provider || Provider::CaAutoBank.new(request_session_id: state.fetch("request_session_id"))
          response = client.poll_login(verification_token: state.fetch("verification_token"))
          result = apply_response!(response, state)
        rescue Provider::CaAutoBank::Error => error
          clear_pending! unless error.code == "challenge_not_available"
          failure = safe_error(error)
        rescue ArgumentError, KeyError, TypeError
          clear_pending!
          failure = Provider::CaAutoBank::Error.new(:challenge_expired)
        end
      end
    end
    raise failure if failure

    result
  end

  def summary(session_id:)
    return unless @item.persisted? && @item.pending_login_state.present?

    @item.with_lock do
      state = read_state
      if state.nil? || expired?(state)
        clear_pending!
        next
      end
      next unless session_matches?(state, session_id)

      { attempt_id: state.fetch("attempt_id"), expires_at: state.fetch("expires_at") }
    end
  end

  def cancel(attempt_id:, session_id:)
    @item.with_lock do
      next false unless matches?(read_state, attempt_id: attempt_id, session_id: session_id)

      clear_pending!
      true
    end
  end

  private

    def apply_response!(response, state)
      fail!(:challenge_expired) if expired?(state)
      fail!(:invalid_session) unless @item.connection_generation == state.fetch("generation")
      if response.authenticated?
        token = response.authentication_token
        expires_at = Provider::CaAutoBank.token_expires_at(token)
        fail!(:session_expired) unless expires_at > Time.current
        client = Provider::CaAutoBank.new(authentication_token: token, request_session_id: state.fetch("request_session_id"))
        identity = client.account_identity
        if @item.account_identity.present? && @item.account_identity != identity
          fail!(:account_identity_changed)
        end
        @item.update!(authentication_token: token, account_identity: identity, pending_login_state: nil,
          request_session_id: state.fetch("request_session_id"), session_expires_at: expires_at,
          connection_generation: @item.connection_generation + 1, status: :connected, last_sync_error_code: nil)
        :authenticated
      else
        state["verification_token"] = response.verification_token
        @item.update!(pending_login_state: JSON.generate(state), status: @item.session_configured? ? :connected : :pending)
        :pending
      end
    end

    def authorize!(session_id)
      owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
      fail!(:login_authorization_changed) unless owner

      owner.with_lock do
        session = Session.lock.find_by(id: session_id, user_id: owner.id)
        valid = owner.active? && owner.admin? && owner.preview_features_enabled? &&
          owner.family.can_connect_ca_auto_bank? && session && session.active_impersonator_session_id.blank?
        fail!(:login_authorization_changed) unless valid

        yield
      end
    end

    def read_state
      value = JSON.parse(@item.pending_login_state) if @item.pending_login_state.present?
      value if value.is_a?(Hash)
    rescue JSON::ParserError, TypeError
      nil
    end

    def matches?(state, attempt_id:, session_id:)
      session_matches?(state, session_id) && state["attempt_id"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(state["attempt_id"].to_s, attempt_id.to_s)
    end

    def session_matches?(state, session_id)
      state.present? && state["owner_id"] == @item.owner_id && state["family_id"] == @item.family_id &&
        state["session_id"].present? && state["session_id"] == session_id.to_s && state["generation"] == @item.connection_generation
    end

    def expired?(state)
      Time.iso8601(state.fetch("expires_at")) <= Time.current
    rescue KeyError, ArgumentError, TypeError
      true
    end

    def clear_pending!
      @item.update!(pending_login_state: nil, status: @item.session_configured? ? :connected : :requires_update)
    end

    def ensure_encryption!
      fail!(:encryption_unavailable) unless ActiveRecordEncryptionConfig.explicitly_configured?
    end

    def safe_error(error)
      Provider::CaAutoBank::Error.new(ERROR_CODES.include?(error.code) ? error.code : :provider_unavailable)
    end

    def fail!(code)
      raise Provider::CaAutoBank::Error.new(code)
    end
end
