class Settings::AiPromptsController < ApplicationController
  layout "settings"
  before_action :set_family

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "AI Prompts", nil ]
    ]
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
  end

  def update
    if @family.update(ai_prompt_params)
      redirect_to settings_ai_prompts_path, notice: t(".success")
    else
      @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
      render :show, status: :unprocessable_entity
    end
  end

  private

    def set_family
      @family = Current.family
    end

    def ai_prompt_params
      params.require(:family).permit(:custom_system_prompt, :custom_intro_prompt, :preferred_ai_model)
    end
end
