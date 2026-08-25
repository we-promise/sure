class Settings::ChancensController < ApplicationController
  layout "settings"

  before_action :ensure_super_admin

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t(".title"), nil ]
    ]
  end

  def update
    if chancen_params.key?(:metabase_url)
      Setting.metabase_url = chancen_params[:metabase_url]
    end

    update_encrypted_setting(:metabase_api_key)

    if chancen_params.key?(:metabase_student_question_id)
      Setting.metabase_student_question_id = chancen_params[:metabase_student_question_id]
    end

    if chancen_params.key?(:metabase_email_param)
      Setting.metabase_email_param = chancen_params[:metabase_email_param].presence || "email"
    end

    redirect_to settings_chancen_path, notice: t(".success")
  end

  private
    def chancen_params
      return ActionController::Parameters.new unless params.key?(:setting)

      params.require(:setting).permit(:metabase_url, :metabase_api_key, :metabase_student_question_id, :metabase_email_param)
    end

    def ensure_super_admin
      redirect_to root_path, alert: t(".not_authorized") unless Current.user.super_admin?
    end

    def update_encrypted_setting(param_key)
      return unless chancen_params.key?(param_key)

      value = chancen_params[param_key].to_s.strip
      return if value == "********"

      Setting.public_send(:"#{param_key}=", value.presence)
    end
end
