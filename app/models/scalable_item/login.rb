class ScalableItem::Login
  MAX_LOGIN_TTL = 20.minutes

  def initialize(item, provider: nil)
    @item = item
    @provider = provider
  end

  def start(session_id:)
    ensure_encryption!
    authorize!(session_id) do
      @item.save! unless @item.persisted?
      with_committed_errors do
        state = read_state
        fail!(:login_in_progress) if state && !expired?(state)
        response = (@provider || Provider::Scalable.new).start_login
        fail!(:invalid_response) unless response.is_a?(Hash)
        deadline = [ Time.iso8601(response.fetch("expires_at")), MAX_LOGIN_TTL.from_now ].min
        fail!(:challenge_expired) if deadline <= Time.current
        state = response.merge(
          "attempt_id" => SecureRandom.urlsafe_base64(24), "session_id" => session_id.to_s,
          "owner_id" => @item.owner_id, "family_id" => @item.family_id,
          "generation" => @item.connection_generation, "expires_at" => deadline.utc.iso8601,
          "deadline" => deadline.utc.iso8601,
          "next_poll_at" => (Time.current + response.fetch("poll_interval", 5).to_i.clamp(5, 60).seconds).utc.iso8601
        )
        validate_verification_url!(state.fetch("verification_url"))
        persist_pending!(state)
        :pending
      end
    end
  rescue ActiveRecord::RecordNotUnique
    fail!(:login_in_progress)
  end

  def poll(attempt_id:, session_id:)
    ensure_encryption!
    authorize!(session_id) do
      with_committed_errors do
        state = read_state
        fail!(:challenge_not_available) unless matches?(state, attempt_id, session_id)
        fail!(:challenge_expired) if expired?(state)
        next :pending if Time.iso8601(state.fetch("next_poll_at")) > Time.current

        provider_state = state.deep_dup
        interval = state.fetch("poll_interval", 5).to_i.clamp(5, 60)
        state["next_poll_at"] = (Time.current + interval.seconds).utc.iso8601
        persist_pending!(state)
        result = (@provider || Provider::Scalable.new).poll_login(provider_state)
        if result.state == :authenticated
          complete!(result.credentials, state)
          :authenticated
        elsif result.state == :pending && result.pending_state.is_a?(Hash)
          provider_state = result.pending_state
          updated = provider_state.merge(state.slice("attempt_id", "session_id", "owner_id", "family_id", "generation", "deadline", "next_poll_at"))
          deadlines = [ Time.iso8601(provider_state.fetch("expires_at")), Time.iso8601(state.fetch("deadline")) ]
          deadlines << Time.iso8601(provider_state["mfa_deadline"]) if provider_state["mfa_deadline"].present?
          deadline = deadlines.min
          updated["expires_at"] = deadline.utc.iso8601
          updated["next_poll_at"] = [ Time.iso8601(provider_state.fetch("next_poll_at", state.fetch("next_poll_at"))), Time.iso8601(state.fetch("next_poll_at")) ].max.utc.iso8601
          validate_verification_url!(updated.fetch("verification_url"))
          persist_pending!(updated)
          :pending
        else
          fail!(:invalid_response)
        end
      end
    end
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

      validate_verification_url!(state.fetch("verification_url"))
      state.slice("attempt_id", "verification_url", "user_code", "expires_at", "phase", "poll_interval").symbolize_keys
    end
  end

  def cancel(attempt_id:, session_id:)
    authorize!(session_id) do
      @item.with_lock do
        next false unless matches?(read_state, attempt_id, session_id)

        clear_pending!
        true
      end
    end
  end

  private

    def complete!(data, state)
      fail!(:challenge_expired) if expired?(state)
      identity = data["person_id"] if data.is_a?(Hash)
      fail!(:invalid_response) unless identity.is_a?(String) && identity.present? &&
        %w[access_token refresh_token private_key_pem].all? { |key| data[key].is_a?(String) && data[key].present? }
      fail!(:account_identity_changed) if @item.person_identity.present? && @item.person_identity != identity

      @item.update!(credentials: JSON.generate(data), person_identity: identity, pending_login_state: nil,
        connection_generation: @item.connection_generation + 1, status: :connected,
        last_sync_error_code: nil, next_sync_at: nil)
    end

    def with_committed_errors
      result = failure = nil
      @item.with_lock do
        begin
          result = yield
        rescue Provider::Scalable::Error => error
          clear_pending! unless %w[login_in_progress challenge_not_available].include?(error.code)
          failure = Provider::Scalable::Error.new(ScalableItem::ERROR_CODES.include?(error.code) ? error.code : :provider_unavailable)
        rescue ArgumentError, KeyError, TypeError
          clear_pending!
          failure = Provider::Scalable::Error.new(:invalid_response)
        rescue StandardError
          clear_pending!
          failure = Provider::Scalable::Error.new(:provider_unavailable)
        end
      end
      raise failure if failure

      result
    end

    def authorize!(session_id)
      fail!(:login_authorization_changed) if session_id.blank?
      owner = User.find_by(id: @item.owner_id, family_id: @item.family_id)
      fail!(:login_authorization_changed) unless owner

      result = failure = nil
      owner.with_lock do
        session = Session.lock.find_by(id: session_id, user_id: owner.id)
        valid = owner.active? && owner.admin? && owner.preview_features_enabled? &&
          owner.family.can_connect_scalable? && session && session.active_impersonator_session_id.blank?
        fail!(:login_authorization_changed) unless valid

        begin
          result = yield
        rescue Provider::Scalable::Error => error
          failure = error
        end
      end
      raise failure if failure

      result
    end

    def read_state
      value = JSON.parse(@item.pending_login_state) if @item.pending_login_state.present?
      value if value.is_a?(Hash)
    rescue JSON::ParserError, TypeError
      nil
    end

    def persist_pending!(state)
      @item.update!(pending_login_state: JSON.generate(state), status: @item.session_configured? ? :connected : :pending)
    end

    def clear_pending!
      @item.update!(pending_login_state: nil, status: @item.session_configured? ? :connected : :requires_update)
    end

    def matches?(state, attempt_id, session_id)
      session_matches?(state, session_id) && state["attempt_id"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(state["attempt_id"].to_s, attempt_id.to_s)
    end

    def session_matches?(state, session_id)
      state.is_a?(Hash) && state["owner_id"] == @item.owner_id && state["family_id"] == @item.family_id &&
        state["session_id"].present? && state["session_id"] == session_id.to_s &&
        state["generation"] == @item.connection_generation
    end

    def expired?(state)
      Time.iso8601(state.fetch("expires_at")) <= Time.current
    rescue KeyError, ArgumentError, TypeError
      true
    end

    def validate_verification_url!(value)
      uri = URI.parse(value.to_s)
      fail!(:invalid_response) unless uri.is_a?(URI::HTTPS) && uri.host == "secure.scalable.capital" &&
        uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      fail!(:invalid_response)
    end

    def ensure_encryption!
      fail!(:encryption_unavailable) unless ActiveRecordEncryptionConfig.explicitly_configured?
    end

    def fail!(code)
      raise Provider::Scalable::Error.new(code)
    end
end
