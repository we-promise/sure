class Bills::ForecastReviewsController < ApplicationController
  include BillsHelper
  include RecurringFeatureGuardable

  guard_feature unless: -> { bills_one_shot_ai_available? }
  before_action :ensure_recurring_enabled

  CATEGORY_LIMIT = 8

  # Seeds a chat like Bills::AiReviewsController, with the forecast written
  # into the message so the model starts from the same figures as the card.
  # Built server-side from the family's own data; nothing comes from the client.
  def create
    chat = Current.user.chats.start!(prompt, model: helpers.default_ai_model)
    Current.user.update!(last_viewed_chat: chat)

    redirect_to chat_path(chat, thinking: true)
  end

  private
    def prompt
      forecast = SpendingForecast.new(Current.family, user: Current.user)
      lines = forecast.rows.first(CATEGORY_LIMIT).map do |row|
        t(".category_line",
          category: row.category&.name || t(".uncategorized"),
          typical: row.typical.format,
          spent: row.spent.format)
      end

      t(".prompt",
        months: forecast.history_months,
        categories: lines.join("\n"),
        remaining: forecast.remaining_this_month.format,
        next_month: forecast.next_month.format)
    end
end
