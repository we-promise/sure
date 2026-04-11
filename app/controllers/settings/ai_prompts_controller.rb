class Settings::AiPromptsController < ApplicationController
  layout "settings"
  before_action :ensure_admin, only: [ :show, :update ]
  before_action :set_family

  def show
    @breadcrumbs = [ [ "Home", root_path ], [ "AI Prompts", nil ] ]
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
    @effective_model = Chat.default_model(@family)
    @show_openai_prompts = show_openai_prompts?
  end

  def update
    if @family.update(family_ai_params)
      redirect_to settings_ai_prompts_path, notice: t(".success")
    else
      @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
      @effective_model = Chat.default_model(@family)
      @show_openai_prompts = show_openai_prompts?
      render :show, status: :unprocessable_entity
    end
  end

  private

    def ensure_admin
      redirect_to root_path, alert: t("settings.ai_prompts.not_authorized") unless Current.user&.admin?
    end

    def set_family
      @family = Current.family
    end

    def family_ai_params
      params.require(:family).permit(:preferred_ai_model, :openai_uri_base)
    end

    def show_openai_prompts?
      @effective_model.blank? || @effective_model.match?(/\A(gpt-|o1-|gpt4)/i)
    end
end
