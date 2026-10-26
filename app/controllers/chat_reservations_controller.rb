class ChatReservationsController < ApplicationController
  include FeatureGuardable

  guard_feature unless: -> { Current.user.ai_enabled? }

  def create
    bubble = ChatReservation.bubble(ChatReservation.hold!)
    render turbo_stream: turbo_stream.update_all(ChatReservation::TARGETS, partial: "chats/reservation", locals: { bubble: bubble })
  end
end
