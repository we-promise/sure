class Provider::Anthropic::ChatParser
  Error = Class.new(StandardError)

  def initialize(message)
    @message = message
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: response_model,
      messages: messages,
      function_requests: function_requests
    )
  end

  private
    ChatResponse = Provider::LlmConcept::ChatResponse
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

    attr_reader :message

    def response_id
      message.id
    end

    def response_model
      message.model.to_s
    end

    def messages
      text_blocks = content_blocks.select { |block| block_type(block) == :text }
      return [] if text_blocks.empty?

      [
        ChatMessage.new(
          id: response_id,
          output_text: text_blocks.map { |b| block_value(b, :text) }.compact.join("\n")
        )
      ]
    end

    def function_requests
      content_blocks
        .select { |block| block_type(block) == :tool_use }
        .map do |block|
          input = block_value(block, :input)
          ChatFunctionRequest.new(
            id: block_value(block, :id),
            call_id: block_value(block, :id),
            function_name: block_value(block, :name),
            # A tool_use block with no arguments streams in as an empty string.
            # Normalize it to an empty JSON object so downstream JSON.parse succeeds.
            function_args: input.is_a?(String) ? input.presence || "{}" : (input || {}).to_json
          )
        end
    end

    def content_blocks
      Array(message.content)
    end

    def block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def block_value(block, key)
      if block.respond_to?(key)
        block.public_send(key)
      elsif block.is_a?(Hash)
        block[key] || block[key.to_s]
      end
    end
end
