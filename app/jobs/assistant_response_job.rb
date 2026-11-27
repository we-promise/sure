class AssistantResponseJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:chat) }

  def perform(message, assistant_message = nil)
    ChatReservation.while_chat_runs { message.request_response(assistant_message: assistant_message) }
  ensure
    # Hold background AI jobs back so a reply to this answer runs next.
    message.chat.hold_reservation
  end
end
