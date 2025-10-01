module Provider::LlmConcept
  extend ActiveSupport::Concern

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args)

  ##
  # Produce a chat response for a given prompt and accompanying metadata.
  # @param [String] prompt - The user's prompt or message to generate a response for.
  # @param [String, Symbol] model - Identifier of the model to use.
  # @param [String, nil] instructions - Optional system or assistant instructions that guide response generation.
  # @param [Array<Hash>] functions - Optional list of function descriptors available to the model (e.g., name, parameters).
  # @param [Array<Hash>] function_results - Optional list of prior function call results to provide context.
  # @param [#call, nil] streamer - Optional callable used to stream response chunks; may be nil for non-streaming.
  # @param [String, nil] previous_response_id - Optional id of a previous response to continue or reference a conversation.
  # @param [String, nil] session_id - Optional session identifier to correlate requests within a user session.
  # @param [String, nil] user_identifier - Optional identifier for the user on whose behalf the response is generated.
  # @return [Provider::LlmConcept::ChatResponse] The generated chat response object.
  # @raise [NotImplementedError] Subclasses must implement #chat_response
  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end
