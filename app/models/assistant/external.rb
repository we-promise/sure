class Assistant::External < Assistant::Base
  Config = Struct.new(:url, :token, :agent_id, :session_key, keyword_init: true)

  # Separate from Assistant::TokenBudget.context_window (LLM_CONTEXT_WINDOW),
  # which budgets the internal OpenAI-compatible path's own model. The
  # external agent is a different, self-hosted-configurable model with its
  # own context window, so it gets its own env var rather than reusing an
  # unrelated setting.
  DEFAULT_MAX_HISTORY_TOKENS = 4096

  class << self
    def for_chat(chat)
      new(chat)
    end

    def configured?
      config.url.present? && config.token.present?
    end

    def available_for?(user)
      configured? && allowed_user?(user)
    end

    def allowed_user?(user)
      allowed = ENV["EXTERNAL_ASSISTANT_ALLOWED_EMAILS"]
      return true if allowed.blank?
      return false if user&.email.blank?

      allowed.split(",").map { |e| e.strip.downcase }.include?(user.email.downcase)
    end

    def config
      Config.new(
        url: ENV["EXTERNAL_ASSISTANT_URL"].presence || Setting.external_assistant_url.presence,
        token: ENV["EXTERNAL_ASSISTANT_TOKEN"].presence || Setting.external_assistant_token.presence,
        agent_id: ENV["EXTERNAL_ASSISTANT_AGENT_ID"].presence || Setting.external_assistant_agent_id.presence || "main",
        session_key: ENV.fetch("EXTERNAL_ASSISTANT_SESSION_KEY", "agent:main:main")
      )
    end

    # `.to_i` on a non-numeric string is 0 rather than raising, unlike
    # Kernel#Integer (which also honors base prefixes like "010" => 8) — safer
    # for an ENV value a self-hoster might typo.
    def max_history_tokens
      configured = ENV["EXTERNAL_ASSISTANT_MAX_HISTORY_TOKENS"].to_s.strip.to_i
      configured.positive? ? configured : DEFAULT_MAX_HISTORY_TOKENS
    end
  end

  def respond_to(message, assistant_message: nil)
    response_completed = false
    assistant_message ||= AssistantMessage.new(chat: chat, content: "", ai_model: "external-agent")

    unless self.class.configured?
      raise Assistant::Error,
        "External assistant is not configured. Set the URL and token in Settings > Self-Hosting or via environment variables."
    end

    unless self.class.allowed_user?(chat.user)
      raise Assistant::Error, "Your account is not authorized to use the external assistant."
    end

    client = build_client
    messages = build_conversation_messages

    model = client.chat(
      messages: messages,
      user: "sure-family-#{chat.user.family_id}"
    ) do |text|
      assistant_message.append_text!(text)
    end

    if assistant_message.content.blank?
      raise Assistant::Error, "External assistant returned an empty response."
    end

    response_completed = true
    assistant_message.update!(ai_model: model) if model.present?
  rescue Assistant::Error, ActiveRecord::ActiveRecordError => e
    cleanup_partial_response(assistant_message) unless response_completed
    chat.add_error(e)
  rescue => e
    Rails.logger.error("[Assistant::External] Unexpected error: #{e.class} - #{e.message}")
    cleanup_partial_response(assistant_message) unless response_completed
    chat.add_error(Assistant::Error.new("Something went wrong with the external assistant. Check server logs for details."))
  end

  private

    def cleanup_partial_response(assistant_message)
      assistant_message&.destroy! if assistant_message&.persisted?
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[Assistant::External] Failed to clean up partial response: #{e.message}")
    end

    def build_client
      Assistant::External::Client.new(
        url: self.class.config.url,
        token: self.class.config.token,
        agent_id: self.class.config.agent_id,
        session_key: self.class.config.session_key
      )
    end

    # Fetches a generous window of recent complete messages, then trims to the
    # configured token budget — bounding both the AI's lost context (was a
    # flat 20-message cap, unrelated to actual content size) and the query's
    # memory footprint on pathologically long chats.
    MAX_FETCHED_MESSAGES = 500

    def build_conversation_messages
      recent = chat.conversation_messages.where(status: "complete")
        .ordered.last(MAX_FETCHED_MESSAGES)
        .map { |msg| { role: msg.role, content: msg.content } }

      Assistant::HistoryTrimmer.new(
        recent,
        max_tokens: self.class.max_history_tokens
      ).call
    end
end
