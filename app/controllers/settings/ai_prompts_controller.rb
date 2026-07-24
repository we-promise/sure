class Settings::AiPromptsController < ApplicationController
  layout "settings"

  before_action :require_admin!

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_prompts"), nil ]
    ]
    @family = Current.family
    @assistant_config = Assistant.config_for(OpenStruct.new(user: Current.user))
  end
end
