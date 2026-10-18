class CaAutoBankLoginsController < ApplicationController
  include CaAutoBankAuthorization

  rescue_from Provider::CaAutoBank::Error, with: :render_login_error

  def show
    prepare_context
  end

  def start
    @ca_auto_bank_item = owned_ca_auto_bank_items.first || owned_ca_auto_bank_items.build(owner: Current.user)
    result = CaAutoBankItem::Login.new(@ca_auto_bank_item).start(
      email: login_params[:email], password: login_params[:password], session_id: Current.session.id.to_s)
    enqueue_first_snapshot if result == :authenticated
    redirect_to ca_auto_bank_login_path, status: :see_other
  end

  def poll
    @ca_auto_bank_item = owned_ca_auto_bank_items.first!
    result = CaAutoBankItem::Login.new(@ca_auto_bank_item).poll(
      attempt_id: login_params[:attempt_id], session_id: Current.session.id.to_s)
    enqueue_first_snapshot if result == :authenticated
    respond_to do |format|
      format.json { render json: { state: result == :authenticated ? "connected" : "pending", redirect_url: accounts_path } }
      format.html { redirect_to(result == :authenticated ? accounts_path : ca_auto_bank_login_path, status: :see_other) }
    end
  end

  def cancel
    @ca_auto_bank_item = owned_ca_auto_bank_items.first
    CaAutoBankItem::Login.new(@ca_auto_bank_item).cancel(
      attempt_id: login_params[:attempt_id], session_id: Current.session.id.to_s) if @ca_auto_bank_item
    redirect_to ca_auto_bank_login_path, status: :see_other
  end

  private

    def prepare_context
      @ca_auto_bank_item = owned_ca_auto_bank_items.first
      @encryption_ready = ActiveRecordEncryptionConfig.explicitly_configured?
      @pending_login = CaAutoBankItem::Login.new(@ca_auto_bank_item).summary(session_id: Current.session.id.to_s) if @ca_auto_bank_item
    end

    def login_params
      params.fetch(:ca_auto_bank_login, ActionController::Parameters.new).permit(:email, :password, :attempt_id)
    end

    def enqueue_first_snapshot
      @ca_auto_bank_item.sync_later unless @ca_auto_bank_item.syncing?
    end

    def render_login_error(error)
      code = CaAutoBankItem::Login::ERROR_CODES.include?(error.code) ? error.code : "provider_unavailable"
      if request.format.json?
        render json: { state: "error", message: t("ca_auto_bank.errors.#{code}") }, status: :unprocessable_entity
      else
        @error_code = code
        prepare_context
        render :show, status: :unprocessable_entity
      end
    end
end
