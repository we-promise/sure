class Settings::AiPromptsController < ApplicationController
  layout "settings"
  before_action :ensure_admin, only: [ :show, :edit_system_prompt, :update ]
  before_action :set_family

  def show
    @breadcrumbs = [ [ "Home", root_path ], [ "AI Prompts", nil ] ]
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
    @effective_model = Chat.default_model(@family)
    @show_openai_prompts = show_openai_prompts?
  end

  def edit_system_prompt
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "AI Prompts", settings_ai_prompts_path ],
      [ t("settings.ai_prompts.show.edit_system_prompt_title"), nil ]
    ]
  end

  def update
    if @family.update(ai_prompt_params)
      redirect_to redirect_after_update, notice: t(".success")
    else
      if params[:from].to_s == "system_prompt"
        render :edit_system_prompt, status: :unprocessable_entity
      else
        @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
        @effective_model = Chat.default_model(@family)
        @show_openai_prompts = show_openai_prompts?
        render :show, status: :unprocessable_entity
      end
    end
  end

  private

    def redirect_after_update
      settings_ai_prompts_path
    end

    def ensure_admin
      redirect_to root_path, alert: t("settings.ai_prompts.not_authorized") unless Current.user&.admin?
    end

    def set_family
      @family = Current.family
    end

    def ai_prompt_params
      params.require(:family).permit(:custom_system_prompt, :custom_intro_prompt, :preferred_ai_model, :openai_uri_base)
    end

    def show_openai_prompts?
      effective = Chat.default_model(@family)
      effective.blank? || effective.match?(/\A(gpt-|o1-|gpt4)/i)
    end
end
