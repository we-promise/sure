class MessagesController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    model = Chat.default_model

    if model.blank?
      flash.now[:alert] = t("chats.no_model_configured")
      render "chats/show", status: :unprocessable_entity
      return
    end

    @message = UserMessage.create!(
      chat: @chat,
      content: message_params[:content],
      ai_model: model
    )

    redirect_to chat_path(@chat, thinking: true)
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    end

    def message_params
      params.require(:message).permit(:content, :ai_model)
    end
end
