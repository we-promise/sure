class Assistant
  include Provided, Configurable, Broadcastable

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
    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: message.ai_model
    )

    llm_provider = get_model_provider(message.ai_model)

    unless llm_provider
      error_message = build_no_provider_error_message(message.ai_model)
      raise StandardError, error_message
    end

    responder = Assistant::Responder.new(
      message: message,
      instructions: instructions,
      function_tool_caller: function_tool_caller,
      llm: llm_provider
    )

    latest_response_id = chat.latest_assistant_response_id

    responder.on(:output_text) do |text|
      if assistant_message.content.blank?
        stop_thinking

        Chat.transaction do
          assistant_message.append_text!(text)
          chat.update_latest_response!(latest_response_id)
        end
      else
        assistant_message.append_text!(text)
      end
    end

    responder.on(:response) do |data|
      update_thinking("Analyzing your data...")

      # Persist the provider's response identifier on the assistant message so
      # future renders reflect the exact metadata used for this conversation
      assistant_message.update!(provider_id: data[:id]) if data[:id].present?

      # Persist the endpoint used for this provider (if applicable)
      if assistant_message.endpoint.blank? && llm_provider.respond_to?(:endpoint_base)
        assistant_message.update!(endpoint: llm_provider.endpoint_base)
      end

      # Persist usage metrics and estimated cost when provided by the LLM provider
      if data[:usage].present?
        usage = data[:usage]

        prompt_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
        completion_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0
        total_tokens = usage["total_tokens"] || (prompt_tokens + completion_tokens)

        estimated_cost = LlmUsage.calculate_cost(
          model: message.ai_model,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens
        )

        assistant_message.update!(
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          total_tokens: total_tokens,
          estimated_cost: estimated_cost
        )
      end

      if data[:function_tool_calls].present?
        assistant_message.tool_calls = data[:function_tool_calls]
        latest_response_id = data[:id]
      else
        chat.update_latest_response!(data[:id])
      end
    end

    responder.respond(previous_response_id: latest_response_id)
  rescue => e
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

    def build_no_provider_error_message(requested_model)
      available_providers = registry.providers

      if available_providers.empty?
        "No LLM provider configured that supports model '#{requested_model}'. " \
        "Please configure an LLM provider (e.g., OpenAI) in settings."
      else
        provider_details = available_providers.map do |provider|
          "  - #{provider.provider_name}: #{provider.supported_models_description}"
        end.join("\n")

        "No LLM provider configured that supports model '#{requested_model}'.\n\n" \
        "Available providers:\n#{provider_details}\n\n" \
        "Please either:\n" \
        "  1. Use a supported model from the list above, or\n" \
        "  2. Configure a provider that supports '#{requested_model}' in settings."
      end
    end
end
