class Bills::AiReviewsController < ApplicationController
  include BillsHelper
  include RecurringFeatureGuardable

  guard_feature unless: -> { bills_one_shot_ai_available? }
  before_action :ensure_recurring_enabled

  # Server-owned on purpose: the button must not become a vector for
  # client-supplied prompts, and the text appears in the chat as the user's
  # own message so it stays short and legible. It reads like something a
  # person would type: no internal tool names, because the tool descriptions
  # already route the model without the prompt naming them.
  REVIEW_PROMPT = <<~PROMPT.freeze
    Review my bills and subscriptions. Look for duplicate bills, price increases, anything overdue or abandoned, trials about to convert, and recurring charges I have not declared yet. Propose specific fixes and ask me before changing anything.
  PROMPT

  # Seeds a chat rather than generating a report: the audit tool grounds the
  # findings deterministically, and a conversation can act on them ("fix the
  # second one") through the bills write tools.
  def create
    chat = Current.user.chats.start!(REVIEW_PROMPT.strip, model: helpers.default_ai_model)
    Current.user.update!(last_viewed_chat: chat)

    redirect_to chat_path(chat, thinking: true)
  end
end
