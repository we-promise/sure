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
  # Produce a chat response from the configured LLM provider using the given prompt and options.
  # @param [String] prompt - The user prompt or conversation content to send to the model.
  # @param [String] model - Identifier of the model to use.
  # @param [String, nil] instructions - Optional high-level instructions or system message to guide the model.
  # @param [Array<Hash>] functions - Optional list of function definitions the model may call.
  # @param [Array<Hash>] function_results - Optional prior function call results to include in the context.
  # @param [#call, nil] streamer - Optional streamer object to receive incremental response chunks.
  # @param [String, nil] previous_response_id - Optional ID of a prior response to continue or reference.
  # @param [String, nil] session_id - Optional session identifier to associate the request with a user session.
  # @param [String, nil] user_identifier - Optional opaque identifier for the end user associated with the request.
  # @return [Provider::LlmConcept::ChatResponse] The assembled chat response including messages and any function requests.
  # @raise [NotImplementedError] Subclasses must implement this method.
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
