class FinecoLoginsController < ApplicationController
  before_action :disable_caching
  before_action :reject_impersonated_session
  before_action :require_self_hosted_fineco
  before_action :require_preview_features!
  before_action :require_admin!

  def show
    @fineco_item = Current.family.fineco_items.find_by(owner_id: Current.user.id)
    @browser_runtime_enabled = FinecoLoginAuthorization.runtime_enabled?
    @encryption_ready = FinecoLoginAuthorization.explicitly_encrypted?
    @capture_enabled = Provider::Fineco.verified_identity_contract?
    @initial_status_key = if !@capture_enabled
      ".status_setup_verification_required"
    elsif @fineco_item&.requires_update?
      ".status_expired"
    elsif @fineco_item&.last_sync_error.present?
      ".status_failed"
    else
      @fineco_item ? ".status_connected" : ".status_ready"
    end
  end

  def start
    return render_error(:encryption_unavailable, :service_unavailable) unless FinecoLoginAuthorization.explicitly_encrypted?

    runtime = browser_runtime
    return render_error(:browser_runtime_unavailable, :service_unavailable) unless runtime

    identity = FinecoLoginAuthorization.identity_for(Current.session)
    return render_error(:session_unavailable, :forbidden) unless identity

    capture_enabled = Provider::Fineco.verified_identity_contract?
    item = Current.family.fineco_items.find_by(owner_id: Current.user.id)
    result = runtime.start(
      identity: identity,
      capture_enabled: capture_enabled,
      on_capture: capture_callback(
        identity: identity,
        existing_item_id: item&.id,
        expected_connection_generation: item&.connection_generation
      ),
      authorized: FinecoLoginAuthorization.method(:authorized?)
    )

    render json: {
      flow_id: safe_flow_id(result.fetch(:id)),
      state: safe_state(result.fetch(:state)),
      expires_at: safe_timestamp(result[:expires_at])
    }, status: :accepted
  rescue StandardError
    render_error(:browser_runtime_unavailable, :service_unavailable)
  end

  def status
    flow_id = requested_flow_id
    return render_error(:invalid_flow, :bad_request) unless flow_id

    runtime = browser_runtime
    return render_error(:browser_runtime_unavailable, :service_unavailable) unless runtime

    identity = FinecoLoginAuthorization.identity_for(Current.session)
    return render_error(:session_unavailable, :forbidden) unless identity

    result = runtime.status(
      identity: identity,
      id: flow_id,
      authorized: FinecoLoginAuthorization.method(:authorized?)
    )

    render json: {
      flow_id: safe_flow_id(result.fetch(:id)),
      state: safe_state(result.fetch(:state)),
      expires_at: safe_timestamp(result[:expires_at])
    }
  rescue StandardError
    render_error(:flow_unavailable, :not_found)
  end

  def stop
    flow_id = requested_flow_id
    return render_error(:invalid_flow, :bad_request) unless flow_id

    runtime = browser_runtime
    return render_error(:browser_runtime_unavailable, :service_unavailable) unless runtime

    identity = FinecoLoginAuthorization.identity_for(Current.session)
    return render_error(:session_unavailable, :forbidden) unless identity

    result = runtime.stop(
      identity: identity,
      id: flow_id,
      reason: :user_cancelled,
      authorized: FinecoLoginAuthorization.method(:authorized?)
    )

    render json: { state: safe_state(result.fetch(:state)) }
  rescue StandardError
    render_error(:flow_unavailable, :not_found)
  end

  private

    def disable_caching
      response.headers["Cache-Control"] = "no-store, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def reject_impersonated_session
      head :forbidden if Current.session&.active_impersonator_session_id.present?
    end

    def require_self_hosted_fineco
      head :not_found unless Rails.application.config.app_mode.self_hosted?
    end

    def browser_runtime
      return unless FinecoLoginAuthorization.runtime_enabled?

      Fineco::BrowserLoginRuntime
    rescue NameError
      nil
    end

    def capture_callback(identity:, existing_item_id:, expected_connection_generation:)
      FinecoItem::LoginCapture.new(
        expected_identity: identity,
        existing_item_id: existing_item_id,
        expected_connection_generation: expected_connection_generation
      )
    end

    def requested_flow_id
      value = params[:id].to_s
      value if value.match?(/\A[a-zA-Z0-9_-]{1,128}\z/)
    end

    def safe_flow_id(value)
      flow_id = value.to_s
      raise ArgumentError unless flow_id.match?(/\A[a-zA-Z0-9_-]{1,128}\z/)

      flow_id
    end

    def safe_state(value)
      state = value.to_s
      return state if %w[starting awaiting_login setup_verification_required capturing stopping captured stopped expired failed rejected].include?(state)

      "unknown"
    end

    def safe_timestamp(value)
      value&.to_time&.utc&.iso8601
    rescue StandardError
      nil
    end

    def render_error(key, status)
      render json: { error: key.to_s }, status: status
    end
end
