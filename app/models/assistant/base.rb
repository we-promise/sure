class Assistant::Base
  attr_reader :chat

  def initialize(chat)
    @chat = chat
  end

  def respond_to(message, assistant_message: nil)
    raise NotImplementedError, "#{self.class}#respond_to must be implemented"
  end
end
