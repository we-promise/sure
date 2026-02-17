class Assistant::External < Assistant::Base
  class << self
    def for_chat(chat)
      new(chat)
    end
  end

  def respond_to(message)
    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: "external"
    )

    update_thinking("Connecting to external assistant...")

    # Placeholder: In the future, this will open a WebSocket connection
    # to an external service (e.g., OpenClaw) and stream the response back.
    #
    # The external service will:
    # 1. Receive the message content + chat context
    # 2. Execute its own functions/tools
    # 3. Stream text chunks back over WebSocket
    # 4. Signal completion
    stop_thinking
    assistant_message.append_text!("External assistant is not yet configured. Please use the built-in assistant.")
  rescue => e
    stop_thinking
    chat.add_error(e)
  end
end
