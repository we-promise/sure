module FinecoLoginAuthorization
  module_function

  def identity_for(session)
    return unless authorized_session?(session)

    {
      family_id: session.user.family_id.to_s,
      user_id: session.user_id.to_s,
      session_id: session.id.to_s
    }
  end

  def identity_from_rack_env(env)
    session_token = ActionDispatch::Request.new(env).cookie_jar.signed[:session_token]
    session = Session.includes(:user).find_by(id: session_token)
    identity_for(session)
  rescue StandardError
    nil
  end

  def authorized?(identity)
    values = identity.to_h.with_indifferent_access
    return false if values.values_at(:family_id, :user_id, :session_id).any?(&:blank?)

    session = Session.includes(:user).find_by(id: values[:session_id])
    return false unless authorized_session?(session)

    user = session.user
    user.id.to_s == values[:user_id].to_s && user.family_id.to_s == values[:family_id].to_s
  rescue StandardError
    false
  end

  def expected_origin(env)
    ActionDispatch::Request.new(env).base_url
  rescue StandardError
    nil
  end

  def runtime_enabled?
    return false unless ENV["FINECO_BROWSER_ENABLED"] == "true" && defined?(Fineco::BrowserLoginRuntime)

    Fineco::BrowserLoginRuntime.runtime_configuration_available?
  rescue StandardError
    false
  end

  def explicitly_encrypted?
    ActiveRecordEncryptionConfig.explicitly_configured?
  end

  def authorized_session?(session)
    return false unless session&.user&.active?
    return false if session.active_impersonator_session_id.present?
    return false unless Rails.application.config.app_mode.self_hosted?
    return false unless ENV["FINECO_BROWSER_ENABLED"] == "true"

    user = session.user
    user.admin? && user.preview_features_enabled?
  end
end
