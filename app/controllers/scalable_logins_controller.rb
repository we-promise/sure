class ScalableLoginsController < ApplicationController
  include ScalableAuthorization

  rescue_from Provider::Scalable::Error, with: :render_login_error

  def show
    prepare_context
  end

  def start
    @scalable_item = owned_scalable_items.first || owned_scalable_items.build(owner: Current.user)
    @scalable_item.start_login!(session_id: current_session_id)

    redirect_to scalable_login_path, status: :see_other
  end

  def poll
    @scalable_item = owned_scalable_items.find_by!(owner_id: Current.user.id)
    result = @scalable_item.poll_login!(
      attempt_id: login_params[:attempt_id],
      session_id: current_session_id
    )

    if result == :authenticated
      @scalable_item.sync_later unless @scalable_item.syncing?
    end

    respond_to do |format|
      format.json do
        if result == :authenticated
          render json: { state: "connected", redirect_url: accounts_path }
        else
          summary = @scalable_item.pending_login_summary(session_id: current_session_id)
          render json: {
            state: "pending",
            phase: safe_phase(summary&.fetch(:phase, "device")),
            expires_at: summary&.fetch(:expires_at),
            poll_interval: summary&.fetch(:poll_interval)
          }.compact
        end
      end
      format.html do
        redirect_to(result == :authenticated ? accounts_path : scalable_login_path, status: :see_other)
      end
    end
  end

  def cancel
    @scalable_item = owned_scalable_items.find_by(owner_id: Current.user.id)
    @scalable_item&.cancel_login!(
      attempt_id: login_params[:attempt_id],
      session_id: current_session_id
    )

    redirect_to scalable_login_path, status: :see_other
  end

  private

    def prepare_context
      @scalable_item = owned_scalable_items.first
      @encryption_ready = ActiveRecordEncryptionConfig.explicitly_configured?
      @pending_login = @scalable_item&.pending_login_summary(session_id: current_session_id)
      @login_in_progress = @scalable_item&.pending_login_state.present? && @pending_login.blank?
    end

    def login_params
      params.fetch(:scalable_login, ActionController::Parameters.new).permit(:attempt_id)
    end

    def safe_phase(phase)
      phase.to_s.in?(%w[device phone_approval]) ? phase.to_s : "device"
    end

    def render_login_error(error)
      @error_code = ScalableItem::ERROR_CODES.include?(error.code.to_s) ? error.code.to_s : "provider_unavailable"
      if request.format.json?
        render json: { state: "error", message: t("scalable.errors.#{@error_code}") }, status: :unprocessable_entity
      else
        prepare_context
        render :show, status: :unprocessable_entity
      end
    end
end
