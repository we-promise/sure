class DirectaLoginsController < ApplicationController
  before_action :disable_caching
  before_action :reject_impersonated_session
  before_action :require_self_hosted_directa
  before_action :require_preview_features!
  before_action :require_admin!

  def show
    prepare_show_context
  end

  def start
    return render_encryption_unavailable unless ActiveRecordEncryptionConfig.explicitly_configured?

    @directa_item = owned_directa_item || Current.family.directa_items.build(owner: Current.user)
    result = @directa_item.start_login!(
      broker_account: start_params[:broker_account],
      password: start_params[:password],
      session_id: current_session_id
    )

    if result == :authenticated
      @directa_item.sync_later unless @directa_item.syncing?
      redirect_to directa_login_path,
        notice: t("directa_logins.show.authenticated_waiting_for_sync"),
        status: :see_other
    else
      redirect_to directa_login_path,
        notice: t("directa_logins.show.otp_requested"),
        status: :see_other
    end
  rescue DirectaItem::Login::Error => error
    prepare_show_context
    @login_error_key = login_error_translation(error.code)
    render :show, status: :unprocessable_entity
  end

  def complete
    return render_encryption_unavailable unless ActiveRecordEncryptionConfig.explicitly_configured?

    @directa_item = owned_directa_item
    return render_challenge_unavailable unless @directa_item

    result = @directa_item.complete_login!(
      otp_code: complete_params[:otp_code],
      attempt_id: complete_params[:attempt_id],
      session_id: current_session_id
    )

    case result
    when :authenticated
      @directa_item.sync_later unless @directa_item.syncing?
      return redirect_to directa_login_path,
        notice: t("directa_logins.show.authenticated_waiting_for_sync"),
        status: :see_other
    when :otp_required
      remaining = @directa_item.pending_login_summary(session_id: current_session_id)&.fetch(:attempts_remaining, 0)
      flash.now[:alert] = t("directa_logins.show.invalid_otp", attempts: remaining)
    when :attempts_exhausted
      @login_error_key = "directa_logins.show.errors.attempts_exhausted"
    end

    prepare_show_context
    render :show, status: :unprocessable_entity
  rescue DirectaItem::Login::Error => error
    prepare_show_context
    @login_error_key = login_error_translation(error.code)
    render :show, status: :unprocessable_entity
  end

  def cancel
    @directa_item = owned_directa_item
    if @directa_item&.cancel_login!(
      attempt_id: complete_params[:attempt_id],
      session_id: current_session_id
    )
      redirect_to directa_login_path, notice: t("directa_logins.show.login_cancelled"), status: :see_other
    else
      redirect_to directa_login_path,
        alert: t("directa_logins.show.errors.challenge_not_available"),
        status: :see_other
    end
  end

  private

    def prepare_show_context
      @directa_item = owned_directa_item
      @encryption_ready = ActiveRecordEncryptionConfig.explicitly_configured?
      @pending_login = @directa_item&.pending_login_summary(session_id: current_session_id)
      @login_in_progress = @directa_item&.pending_login_state.present? && @pending_login.blank?
    end

    def owned_directa_item
      Current.family.directa_items.owned_by(Current.user).find_by(owner_id: Current.user.id)
    end

    def current_session_id
      Current.session&.id.to_s
    end

    def start_params
      params.fetch(:directa_login, ActionController::Parameters.new).permit(:broker_account, :password)
    end

    def complete_params
      params.fetch(:directa_login, ActionController::Parameters.new).permit(:otp_code, :attempt_id)
    end

    def login_error_translation(code)
      safe_code = DirectaItem::Login::LOGIN_ERROR_CODES.include?(code.to_s) ? code.to_s : "authentication_failed"
      "directa_logins.show.errors.#{safe_code}"
    end

    def render_encryption_unavailable
      prepare_show_context
      @login_error_key = "directa_logins.show.errors.encryption_unavailable"
      render :show, status: :service_unavailable
    end

    def render_challenge_unavailable
      prepare_show_context
      @login_error_key = "directa_logins.show.errors.challenge_not_available"
      render :show, status: :unprocessable_entity
    end

    def disable_caching
      response.headers["Cache-Control"] = "no-store, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def reject_impersonated_session
      head :forbidden if Current.session&.active_impersonator_session_id.present?
    end

    def require_self_hosted_directa
      head :not_found unless Rails.application.config.app_mode.self_hosted? && Current.family.can_connect_directa?
    end
end
