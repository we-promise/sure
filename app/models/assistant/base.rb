class Assistant::Base
  include Assistant::Broadcastable

  attr_reader :chat

  def self.for_chat(chat)
    raise NotImplementedError, "#{name} must implement .for_chat"
  end

  def initialize(chat)
    @chat = chat
  end

  def respond_to(message)
    raise NotImplementedError, "#{self.class.name} must implement #respond_to"
  end
end
