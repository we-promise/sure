class Assistant
  include Provided, Configurable, Broadcastable, Assistant::Provided

  attr_reader :chat, :instructions

  class << self
    def for_chat(chat)
      config = config_for(chat)
      new(chat, instructions: config[:instructions], functions: config[:functions])
    end
  end

  def initialize(chat, instructions: nil, functions: [])
    @chat = chat
    @instructions = instructions
    @functions = functions
  end

  def respond_to(message)
    Rails.logger.info ">>> Assistant respond_to called with message: #{message.inspect}"
    Rails.logger.info ">>> Assistant message ai_model: #{message.ai_model}"

    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: message.ai_model
    )

    Rails.logger.info ">>> Assistant created AssistantMessage: #{assistant_message.inspect}"

    responder = Assistant::Responder.new(
      message: message,
      instructions: instructions,
      function_tool_caller: function_tool_caller,
      llm: get_model_provider(message.ai_model)
    )

    Rails.logger.info ">>> Assistant created responder with LLM: #{responder.instance_variable_get(:@llm).class}"

    latest_response_id = chat.latest_assistant_response_id

    responder.on(:output_text) do |text|
      Rails.logger.info ">>> Assistant received output_text: '#{text}'"
      Rails.logger.info ">>> Assistant current assistant_message.content: '#{assistant_message.content}'"

      if assistant_message.content.blank?
        stop_thinking

        Chat.transaction do
          Rails.logger.info ">>> Assistant appending first text to message: '#{text}'"
          assistant_message.append_text!(text)
          Rails.logger.info ">>> Assistant after append_text, content: '#{assistant_message.content}'"
          chat.update_latest_response!(latest_response_id)
        end
      else
        Rails.logger.info ">>> Assistant appending additional text: '#{text}'"
        assistant_message.append_text!(text)
        Rails.logger.info ">>> Assistant after additional append, content: '#{assistant_message.content}'"
      end
    end

    responder.on(:response) do |data|
      Rails.logger.info ">>> Assistant received response data: #{data.inspect}"
      update_thinking("Analyzing your data...")

      if data[:function_tool_calls].present?
        assistant_message.tool_calls = data[:function_tool_calls]
        latest_response_id = data[:id]
      else
        chat.update_latest_response!(data[:id])
      end
    end

    Rails.logger.info ">>> Assistant calling responder.respond"
    result = responder.respond(previous_response_id: latest_response_id)
    Rails.logger.info ">>> Assistant responder.respond returned: #{result.inspect}"
    result
  rescue => e
    Rails.logger.error ">>> Assistant error: #{e.class}: #{e.message}"
    Rails.logger.error ">>> Assistant error backtrace: #{e.backtrace.first(5).join('\n')}"
    stop_thinking
    chat.add_error(e)
  end

  private
    attr_reader :functions

    def function_tool_caller
      function_instances = functions.map do |fn|
        fn.new(chat.user)
      end

      @function_tool_caller ||= FunctionToolCaller.new(function_instances)
    end
end
