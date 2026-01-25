class Settings::AiPromptsController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_prompts"), nil ]
    ]

    # Assistant instructions require a chat context for currency/date format
    preview_chat = @chat || Current.user.chats.new

    @assistant_config = {
      instructions: Assistant.config_for(preview_chat)[:instructions],
      auto_categorizer: Provider::Openai::AutoCategorizer.new(nil, model: "", transactions: [], user_categories: []),
      auto_merchant: Provider::Openai::AutoMerchantDetector.new(nil, model: "", transactions: [], user_merchants: [])
    }
  end
end