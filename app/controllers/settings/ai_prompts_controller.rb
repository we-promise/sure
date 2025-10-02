class Settings::AiPromptsController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "AI Prompts", nil ]
    ]
    @family = Current.family
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
  end
end
