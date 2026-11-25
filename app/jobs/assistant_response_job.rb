class AssistantResponseJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:chat) }

  def perform(message, assistant_message = nil)
    message.request_response(assistant_message: assistant_message)
  end
end
