class Settings::AiPromptsController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("layouts.application.nav.home"), root_path ],
      [ t("settings.settings_nav.ai_prompts_label"), nil ]
    ]
    @family = Current.family
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
  end
end
