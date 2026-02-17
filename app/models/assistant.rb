module Assistant
  REGISTRY = {
    "builtin" => "Assistant::Builtin",
    "external" => "Assistant::External"
  }.freeze

  def self.for_chat(chat)
    type = chat.user.family.assistant_type
    klass = REGISTRY.fetch(type, REGISTRY["builtin"]).constantize
    klass.for_chat(chat)
  end

  def self.config_for(chat)
    Assistant::Builtin.config_for(chat)
  end

  def self.available_types
    REGISTRY.keys
  end
end
