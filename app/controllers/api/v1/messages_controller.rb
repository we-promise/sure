# frozen_string_literal: true

class Api::V1::MessagesController < Api::V1::BaseController
  before_action :require_ai_enabled
  before_action :ensure_write_scope, only: [ :create, :retry ]
  before_action :set_chat

  def create
    @message = @chat.messages.build(
      content: message_params[:content],
      type: "UserMessage",
      ai_model: message_params[:model].presence || Chat.default_model
    )

    if @message.save
      # NOTE: Commenting out duplicate job enqueue to fix mobile app receiving duplicate AI responses
      # UserMessage model already triggers AssistantResponseJob via after_create_commit callback
      # in app/models/user_message.rb:10-12, so this manual enqueue causes the job to run twice,
      # resulting in duplicate AI responses with different content and wasted tokens.
      # See: https://github.com/dwvwdv/sure (mobile app integration issue)
      # AssistantResponseJob.perform_later(@message)
      render :show, status: :created
    else
      render json: { error: "Failed to create message", details: @message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def retry
    reply = @chat.retry_last_message!

    if reply
      render json: { message: "Retry initiated", message_id: reply.id }, status: :accepted
    else
      render json: { error: "No assistant message to retry" }, status: :unprocessable_entity
    end
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_chat
      @chat = current_resource_owner.chats.find(params[:chat_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def message_params
      params.permit(:content, :model)
    end
end
