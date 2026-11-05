module Provider::Anthropic::Concerns::StructuredOutput
  extend ActiveSupport::Concern

  private

    # Sends a request that expects its result through a single tool. On the
    # `auto` path (models that reject a forced tool_choice) the model may answer
    # with text only, so one retry asks for the tool again in the prompt. The
    # retry keeps `auto`: those models answer a forced tool with a 400.
    #
    # The first response is billed even though it carried no result, so its
    # usage is recorded here, and so is the retry's when it fails too (the caller
    # raises then); the caller records a successful final response as usual.
    def create_structured_message(tool_name:, operation:, **params)
      response = client.messages.create(**params)
      return response unless retry_for_missing_tool?(response, params[:tool_choice])

      record_usage(model, response.usage, operation: operation, metadata: { attempt: 1, retried: true })
      retry_response = client.messages.create(**params, messages: params[:messages] + tool_retry_messages(response, tool_name))
      if Array(retry_response.content).none? { |block| structured_block_type(block) == :tool_use }
        record_usage(model, retry_response.usage, operation: operation, metadata: { attempt: 2, retried: true })
      end
      retry_response
    end

    def retry_for_missing_tool?(response, tool_choice)
      tool_choice.is_a?(Hash) &&
        tool_choice[:type] == "auto" &&
        response.respond_to?(:stop_reason) &&
        response.stop_reason.to_s == "end_turn" &&
        Array(response.content).none? { |block| structured_block_type(block) == :tool_use }
    end

    def tool_retry_messages(response, tool_name)
      text = Array(response.content).filter_map { |block| structured_block_text(block) }.join("\n").strip
      reminder = { role: "user", content: "You did not call the #{tool_name} tool. Call it now with the result; do not answer with text." }

      text.empty? ? [ reminder ] : [ { role: "assistant", content: text }, reminder ]
    end

    def structured_block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def structured_block_input(block)
      block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    end

    def structured_block_text(block)
      return unless structured_block_type(block) == :text

      block.respond_to?(:text) ? block.text.presence : (block[:text] || block["text"]).presence
    end
end
