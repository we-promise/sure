class ChatReservationsController < ApplicationController
  include FeatureGuardable

  guard_feature unless: -> { Current.user.ai_enabled? }

  def create
    endpoint = Ai::Sequencer.chat_endpoint(Current.user)
    bubble = ChatReservation.bubble(endpoint, ChatReservation.hold!(endpoint))
    render turbo_stream: turbo_stream.update_all(ChatReservation::TARGETS, partial: "chats/reservation", locals: { bubble: bubble })
  end
end
