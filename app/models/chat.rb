class Chat < ApplicationRecord
  include Debuggable

  belongs_to :user

  has_one :viewer, class_name: "User", foreign_key: :last_viewed_chat_id, dependent: :nullify # "Last chat user has viewed"
  has_many :messages, dependent: :destroy

  validates :title, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  class << self
    def start!(prompt, model:)
      raise ArgumentError, "No AI model configured. Please set a model in Settings → Self-Hosted → AI Settings." if model.blank?

      create!(
        title: generate_title(prompt),
        messages: [ UserMessage.new(content: prompt, ai_model: model) ]
      )
    end

    def generate_title(prompt)
      prompt.first(80)
    end

    # Returns the model explicitly configured in settings (ENV overrides setting).
    # Returns nil if nothing is configured — callers must handle that case.
    def default_model
      Provider::Openai.effective_model
    end
  end

  def needs_assistant_response?
    conversation_messages.ordered.last.role != "assistant"
  end

  def retry_last_message!
    update!(error: nil)

    last_message = conversation_messages.ordered.last

    if last_message.present? && last_message.role == "user"
      last_message.update!(ai_model: self.class.default_model)

      ask_assistant_later(last_message)
    end
  end

  def update_latest_response!(provider_response_id)
    update!(latest_assistant_response_id: provider_response_id)
  end

  def add_error(e)
    update! error: e.to_json
    broadcast_append target: "messages", partial: "chats/error", locals: { chat: self }
  end

  def display_error_message
    payload = parsed_error_payload
    return error.to_s if payload.blank?

    payload.dig("details", "error", "message").presence ||
      payload["message"].presence ||
      payload.dig("error", "message").presence ||
      error.to_s
  end

  def clear_error
    update! error: nil
    broadcast_remove target: "chat-error"
  end

  def assistant
    @assistant ||= Assistant.for_chat(self)
  end

  def ask_assistant_later(message)
    clear_error
    AssistantResponseJob.perform_later(message)
  end

  def ask_assistant(message)
    assistant.respond_to(message)
  end

  def conversation_messages
    messages.where(type: [ "UserMessage", "AssistantMessage" ])
  end

  private
    # Errors can be persisted either as a JSON object string or as a quoted JSON
    # string. Parse progressively to normalize both shapes for UI rendering.
    def parsed_error_payload
      return if error.blank?

      parsed = error

      2.times do
        break unless parsed.is_a?(String)
        candidate = parsed.strip
        break unless candidate.start_with?("{", "\"")

        decoded = JSON.parse(candidate) rescue nil
        break if decoded.nil?

        parsed = decoded
      end

      parsed if parsed.is_a?(Hash)
    end
end
