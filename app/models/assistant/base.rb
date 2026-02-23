class Assistant::Base
  include Assistant::Broadcastable

  attr_reader :chat

  def initialize(chat)
    @chat = chat
  end

  def respond_to(message)
    raise NotImplementedError, "#{self.class}#respond_to must be implemented"
  end
end
