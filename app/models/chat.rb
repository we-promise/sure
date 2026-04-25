class Chat < ApplicationRecord
  include Debuggable

  RATE_LIMIT_PATTERNS = [
    /\b429\b/i,
    /rate limit/i,
    /too many requests/i,
    /quota exceeded/i
  ].freeze

  TEMPORARY_PROVIDER_PATTERNS = [
    /\b5\d\d\b/i,
    /service unavailable/i,
    /temporarily unavailable/i,
    /gateway timeout/i,
    /bad gateway/i,
    /overloaded/i,
    /timed? out/i,
    /connection reset/i
  ].freeze

  AUTH_CONFIGURATION_PATTERNS = [
    /unauthorized/i,
    /authentication/i,
    /invalid api key/i,
    /incorrect api key/i,
    /access token/i
  ].freeze

  belongs_to :user

  has_one :viewer, class_name: "User", foreign_key: :last_viewed_chat_id, dependent: :nullify # "Last chat user has viewed"
  has_many :messages, dependent: :destroy

  validates :title, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  class << self
    def start!(prompt, model:)
      # Ensure we have a valid model by using the default if none provided
      effective_model = model.presence || default_model

      create!(
        title: generate_title(prompt),
        messages: [ UserMessage.new(content: prompt, ai_model: effective_model) ]
      )
    end

    def generate_title(prompt)
      prompt.first(80)
    end

    # Returns the default AI model to use for chats
    # Priority: AI Config > Setting
    def default_model
      Provider::Openai.effective_model.presence || Setting.openai_model
    end
  end

  def needs_assistant_response?
    conversation_messages.ordered.last.role != "assistant"
  end

  def retry_last_message!
    update!(error: nil)

    last_message = conversation_messages.ordered.last

    if last_message.present? && last_message.role == "user"

      ask_assistant_later(last_message)
    end
  end

  def update_latest_response!(provider_response_id)
    update!(latest_assistant_response_id: provider_response_id)
  end

  def add_error(e)
    update!(error: build_error_payload(e).to_json)
    broadcast_append target: "messages", partial: "chats/error", locals: { chat: self }
  end

  def presentable_error_message
    parsed_error_payload["message"].presence || error
  end

  def technical_error_message
    parsed_error_payload["technical_message"].presence || error
  end

  def clear_error
    update! error: nil
    broadcast_remove target: "chat-error"
  end

  def build_error_payload(error)
    technical_message = error_message_for(error)

    {
      message: classify_error_message(technical_message),
      technical_message: technical_message,
      type: error.class.name
    }
  end

  def classify_error_message(message)
    normalized_message = message.to_s.strip
    return "Failed to generate a response. Please try again." if normalized_message.blank?

    if RATE_LIMIT_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
      "The AI provider is rate limited right now. Please try again in a few minutes."
    elsif TEMPORARY_PROVIDER_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
      "The AI provider is temporarily unavailable right now. Please try again in a few minutes."
    elsif AUTH_CONFIGURATION_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
      "The AI provider is not configured correctly. Please contact your administrator."
    else
      "Failed to generate a response. Please try again."
    end
  end

  def parsed_error_payload
    return {} if error.blank?

    JSON.parse(error)
  rescue JSON::ParserError
    {}
  end

  def error_message_for(error)
    error.respond_to?(:message) ? error.message.to_s : error.to_s
  rescue
    ""
  end

  def conversation_messages
    messages.where(type: [ "UserMessage", "AssistantMessage" ])
  end

  def ask_assistant_later(message)
    clear_error
    AssistantResponseJob.perform_later(message)
  end

  def ask_assistant(message)
    assistant.respond_to(message)
  end

  private

    def assistant
      @assistant ||= Assistant.for_chat(self)
    end
end
