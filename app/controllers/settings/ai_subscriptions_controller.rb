# frozen_string_literal: true

class Settings::AiSubscriptionsController < ApplicationController
  layout "settings"

  before_action :require_admin!

  def show
    @codex_available = defined?(Provider::Codex) && Provider::Codex.configured?
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_subscriptions"), nil ]
    ]
  end
end
