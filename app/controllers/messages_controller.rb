class MessagesController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    @message = UserMessage.new(
      chat: @chat,
      content: message_params[:content],
      ai_model: message_params[:ai_model].presence || Chat.default_model
    )

    if @message.save
      redirect_to chat_path(@chat, thinking: true)
    else
      redirect_to chat_path(@chat), alert: @message.errors.full_messages.to_sentence
    end
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    end

    def message_params
      params.require(:message).permit(:content, :ai_model)
    end
end
