class Assistant::External < Assistant::Base
  Config = Struct.new(:url, :token, :agent_id, :session_key, keyword_init: true)

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
      allowed.split(",").map(&:strip).include?(user.email)
    end

    def config
      Config.new(
        url: ENV["EXTERNAL_ASSISTANT_URL"],
        token: ENV["EXTERNAL_ASSISTANT_TOKEN"],
        agent_id: ENV.fetch("EXTERNAL_ASSISTANT_AGENT_ID", "main"),
        session_key: ENV.fetch("EXTERNAL_ASSISTANT_SESSION_KEY", "agent:main:main")
      )
    end
  end

  def respond_to(message)
    unless self.class.configured?
      raise Assistant::Error,
        "External assistant is not configured. Set EXTERNAL_ASSISTANT_URL and EXTERNAL_ASSISTANT_TOKEN environment variables."
    end

    unless self.class.allowed_user?(chat.user)
      raise Assistant::Error, "Your account is not authorized to use the external assistant."
    end

    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: "external"
    )

    client = build_client
    messages = build_conversation_messages

    model = client.chat(
      messages: messages,
      user: "sure-family-#{chat.user.family_id}"
    ) do |text|
      if assistant_message.content.blank?
        stop_thinking
        assistant_message.content = text
        assistant_message.save!
      else
        assistant_message.append_text!(text)
      end
    end

    if assistant_message.new_record?
      stop_thinking
      raise Assistant::Error, "External assistant returned an empty response."
    end

    assistant_message.update!(ai_model: model) if model.present?
  rescue => e
    stop_thinking
    chat.add_error(e)
  end

  private

    def build_client
      Assistant::External::Client.new(
        url: self.class.config.url,
        token: self.class.config.token,
        agent_id: self.class.config.agent_id,
        session_key: self.class.config.session_key
      )
    end

    def build_conversation_messages
      chat.conversation_messages.ordered.map do |msg|
        { role: msg.role, content: msg.content }
      end
    end
end
