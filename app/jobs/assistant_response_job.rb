class AssistantResponseJob < ApplicationJob
  queue_as :ai_high_priority

  def perform(message, assistant_message = nil)
    message.request_response(assistant_message: assistant_message)
  end
end
