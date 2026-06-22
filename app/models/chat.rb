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
    /time(?:out|d?\s*out)/i,
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

    # Returns the default AI model to use for chats.
    # Resolved from the configured llm_provider so installs that swap providers
    # don't have to manually update every chat default. Falls through to a
    # provider that actually has credentials configured, otherwise the chosen
    # provider's classes would later raise "no LLM provider supports model …"
    # even when the other provider is configured.
    def default_model
      prefers_anthropic = Setting.llm_provider == "anthropic"

      if prefers_anthropic && Provider::Anthropic.configured?
        Provider::Anthropic.effective_model.presence || Setting.anthropic_model
      elsif Provider::Openai.configured?
        Provider::Openai.effective_model.presence || Setting.openai_model
      elsif Provider::Anthropic.configured?
        Provider::Anthropic.effective_model.presence || Setting.anthropic_model
      else
        Provider::Openai.effective_model.presence || Setting.openai_model
      end
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
    broadcast_append target: messages_target, partial: "chats/error", locals: { chat: self }
  end

  def presentable_error_message
    return nil if error.blank?
    parsed_error_payload["message"].presence || classify_error_message(error)
  end

  def technical_error_message
    parsed_error_payload["technical_message"].presence || parsed_legacy_error_message || error
  end

  def clear_error
    update! error: nil
    broadcast_remove target: error_target
  end

  def conversation_messages
    messages.where(type: [ "UserMessage", "AssistantMessage" ])
  end

  def messages_target
    ActionView::RecordIdentifier.dom_id(self, :messages)
  end

  def error_target
    ActionView::RecordIdentifier.dom_id(self, :chat_error)
  end

  def ask_assistant_later(message)
    clear_error
    pending = messages.create!(type: "AssistantMessage", content: "", ai_model: message.ai_model, status: :pending)
    AssistantResponseJob.perform_later(message, pending)
  end

  def ask_assistant(message, assistant_message: nil)
    assistant.respond_to(message, assistant_message: assistant_message)
  end

  # Minimum age before the server will treat a still-pending response as
  # undelivered. The browser watchdog waits longer (default 90s) before it even
  # asks, but the client clock is untrusted, so the server enforces its own floor.
  UNDELIVERED_RESPONSE_TIMEOUT = 60.seconds

  # Handles the case where an assistant response was never delivered — the
  # background worker never ran `AssistantResponseJob` (or it died before it
  # could broadcast an error), leaving a `pending` "Thinking…" bubble forever.
  # Mirrors `Assistant::Builtin`'s rescue: clears the dead bubble, records a
  # friendly error + a debug log entry, and broadcasts the error/Retry UI.
  #
  # Driven by an untrusted client watchdog, so the state change is gated behind a
  # row lock + a server-side age check: we re-read the row under lock and only act
  # if it is *still* pending and has genuinely waited past the timeout, so we never
  # race a worker that is finishing a legitimate (slow) response.
  def handle_undelivered_response!(assistant_message)
    return false unless assistant_message.is_a?(AssistantMessage)

    resolved = assistant_message.with_lock do
      next false unless assistant_message.pending?
      next false if assistant_message.created_at > UNDELIVERED_RESPONSE_TIMEOUT.ago

      if assistant_message.content.blank?
        assistant_message.destroy!
      else
        # Demote partially-streamed turns to `failed` so history builders exclude them.
        assistant_message.update_columns(status: "failed")
      end
      true
    end

    return false unless resolved

    capture_undelivered_response!(assistant_message)
    update!(error: undelivered_error_payload(assistant_message).to_json)
    broadcast_append target: messages_target, partial: "chats/error", locals: { chat: self }
    true
  end

  private

    def undelivered_error_payload(assistant_message)
      {
        message: I18n.t("chat.errors.no_response"),
        technical_message: "Assistant response was never delivered. The background worker did not process " \
          "AssistantResponseJob for message ##{assistant_message.id} (model #{assistant_message.ai_model}). " \
          "#{BackgroundJobHealth.summary}",
        type: "DeliveryTimeout"
      }
    end

    def capture_undelivered_response!(assistant_message)
      DebugLogEntry.capture(
        category: "assistant",
        level: "error",
        message: "Assistant response not delivered — background worker likely down or not polling the high_priority queue",
        source: "chat.delivery_timeout",
        metadata: {
          chat_id: id,
          message_id: assistant_message.id,
          ai_model: assistant_message.ai_model,
          waited_seconds: (Time.current - assistant_message.created_at).round,
          background_jobs: BackgroundJobHealth.snapshot
        },
        family: user&.family
      )
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
      return I18n.t("chat.errors.default") if normalized_message.blank?

      if RATE_LIMIT_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
        I18n.t("chat.errors.rate_limited")
      elsif TEMPORARY_PROVIDER_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
        I18n.t("chat.errors.temporarily_unavailable")
      elsif AUTH_CONFIGURATION_PATTERNS.any? { |pattern| normalized_message.match?(pattern) }
        I18n.t("chat.errors.misconfigured")
      else
        I18n.t("chat.errors.default")
      end
    end

    def parsed_error_payload
      return {} if error.blank?
      return error if error.is_a?(Hash)

      parsed = JSON.parse(error)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, TypeError
      {}
    end

    def error_message_for(error)
      error.respond_to?(:message) ? error.message.to_s : error.to_s
    rescue StandardError
      ""
    end

    def parsed_legacy_error_message
      parsed = JSON.parse(error)
      parsed.is_a?(String) ? parsed : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    def assistant
      @assistant ||= Assistant.for_chat(self)
    end
end
