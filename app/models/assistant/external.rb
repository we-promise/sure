class Assistant::External < Assistant::Base
  class << self
    def for_chat(chat)
      new(chat)
    end
  end

  def respond_to(message)
    stop_thinking
    chat.add_error(
      StandardError.new("External assistant (OpenClaw/WebSocket) is not yet implemented.")
    )
  end
end
