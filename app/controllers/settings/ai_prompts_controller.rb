class Settings::AiPromptsController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_prompts"), nil ]
    ]

    @assistant_config = {
      instructions: Provider::Openai::Assistant.new(nil).instructions,
      auto_categorizer: Provider::Openai::AutoCategorizer.new(nil),
      auto_merchant: Provider::Openai::AutoMerchantDetector.new(nil, model: "", transactions: [], user_merchants: [])
    }
  end
end