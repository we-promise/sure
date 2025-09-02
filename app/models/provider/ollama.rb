require "net/http"
require "uri"
require "json"

class Provider::Ollama < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Ollama::Error
  Error = Class.new(Provider::Error)

  # Common Ollama models
  MODELS = %w[
    llama3.2
    llama3.2:3b
    llama3.2:1b
    llama3.1
    llama3.1:8b
    llama3.1:70b
    qwen2.5
    qwen2.5:7b
    qwen2.5:14b
    qwen2.5:32b
    mistral
    mistral:7b
    gemma2
    gemma2:2b
    gemma2:9b
    phi3
    phi3:mini
    codellama
    codellama:7b
  ]

  def initialize(base_url)
    @base_url = base_url.chomp("/")
  end

  def supports_model?(model)
    MODELS.include?(model) || available_models.include?(model)
  end

  def auto_categorize(transactions: [], user_categories: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25

      result = Provider::Ollama::AutoCategorizer.new(
        self,
        model: model,
        transactions: transactions,
        user_categories: user_categories
      ).auto_categorize

      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      result = Provider::Ollama::AutoMerchantDetector.new(
        self,
        model: model,
        transactions: transactions,
        user_merchants: user_merchants
      ).auto_detect_merchants

      result
    end
  end

  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil)
    with_provider_response do
      Rails.logger.info ">>> Ollama chat_response called with prompt: '#{prompt}', model: '#{model}'"
      Rails.logger.info ">>> Ollama instructions: #{instructions.inspect}"
      Rails.logger.info ">>> Ollama streamer present: #{streamer.present?}"

      messages = build_messages(prompt, instructions, function_results)
      Rails.logger.info ">>> Ollama built messages: #{messages.inspect}"

      payload = {
        model: model,
        messages: messages,
        stream: streamer.present?
      }

      # Add function tools if provided
      if functions.any?
        payload[:tools] = functions.map { |fn| format_tool(fn) }
      end

      Rails.logger.info ">>> Ollama final payload: #{payload.inspect}"

      result = if streamer.present?
        handle_streaming_response(payload, streamer)
      else
        handle_non_streaming_response(payload)
      end

      Rails.logger.info ">>> Ollama chat_response returning result: #{result.inspect}"
      result
    end
  rescue => error
    Rails.logger.error ">>> Ollama chat_response error: #{error.class}: #{error.message}"
    Rails.logger.error ">>> Ollama error backtrace: #{error.backtrace.first(5).join('\n')}"
    raise Error, "Ollama chat error: #{error.message}"
  end

  # Ollama-specific method to get available models
  def available_models
    uri = URI("#{base_url}/api/tags")
    response = Net::HTTP.get_response(uri)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      data["models"]&.map { |model| model["name"] } || []
    else
      raise Error, "Ollama API returned status #{response.code}: #{response.message}"
    end
  rescue Net::ConnectTimeoutError, Net::TimeoutError => e
    raise Error, "Connection timeout to Ollama at #{base_url}"
  rescue Errno::ECONNREFUSED => e
    raise Error, "Cannot connect to Ollama at #{base_url}. Make sure Ollama is running."
  rescue => e
    Rails.logger.warn("Failed to fetch Ollama models: #{e.message}")
    raise Error, "Failed to connect to Ollama: #{e.message}"
  end

  # Simple chat method for categorization/merchant detection
  def simple_chat(messages, model:)
    uri = URI("#{base_url}/api/chat")
    payload = {
      model: model,
      messages: messages,
      stream: false
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 60
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = payload.to_json

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      raise Error, "Ollama API error: #{response.code} - #{response.body}"
    end
  end

  private
    attr_reader :base_url

    def build_messages(prompt, instructions, function_results)
      messages = []

      if instructions.present?
        messages << { role: "system", content: instructions }
      end

      messages << { role: "user", content: prompt }

      # Add function results as assistant messages
      function_results.each do |result|
        messages << {
          role: "assistant",
          content: "Function call result: #{result[:output]}"
        }
      end

      messages
    end

    def format_tool(function)
      {
        type: "function",
        function: {
          name: function[:name],
          description: function[:description],
          parameters: function[:params_schema]
        }
      }
    end

    def handle_streaming_response(payload, streamer)
      Rails.logger.info ">>> Ollama handle_streaming_response called with payload: #{payload.inspect}"
      collected_content = ""
      tool_calls = []

      uri = URI("#{base_url}/api/chat")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 60
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      Rails.logger.info ">>> Ollama streaming request to #{uri}"

      http.request(request) do |response|
        if response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            chunk.each_line do |line|
              next if line.strip.empty?

              begin
                data = JSON.parse(line)
                Rails.logger.info ">>> Ollama streaming received data: #{data.inspect}"

                # Extract tool calls from first chunk
                if data["message"] && data["message"]["tool_calls"] && tool_calls.empty?
                  tool_calls = data["message"]["tool_calls"]
                  Rails.logger.info ">>> Ollama extracted tool_calls: #{tool_calls.inspect}"
                end

                # Extract content from chunks
                if data["message"] && data["message"]["content"]
                  chunk_content = data["message"]["content"]
                  Rails.logger.info ">>> Ollama streaming chunk_content: '#{chunk_content}'"
                  collected_content += chunk_content

                  # Only send non-empty chunks to streamer
                  if chunk_content.present?
                    Rails.logger.info ">>> Ollama sending non-empty chunk to streamer: '#{chunk_content}'"
                    chunk = Provider::LlmConcept::ChatStreamChunk.new(
                      type: "output_text",
                      data: chunk_content
                    )
                    streamer.call(chunk)
                  else
                    Rails.logger.info ">>> Ollama skipping empty chunk"
                  end
                end

                if data["done"]
                  Rails.logger.info ">>> Ollama streaming done, collected_content: '#{collected_content}'"
                  Rails.logger.info ">>> Ollama streaming done, tool_calls: #{tool_calls.inspect}"

                  # Build function requests from tool calls
                  function_requests = tool_calls.map do |tool_call|
                    Provider::LlmConcept::ChatFunctionRequest.new(
                      id: SecureRandom.uuid,
                      call_id: SecureRandom.uuid,
                      function_name: tool_call.dig("function", "name"),
                      function_args: JSON.parse(tool_call.dig("function", "arguments") || "{}")
                    )
                  end

                  # Send final response
                  response_data = Provider::LlmConcept::ChatResponse.new(
                    id: SecureRandom.uuid,
                    model: payload[:model],
                    messages: [
                      Provider::LlmConcept::ChatMessage.new(
                        id: SecureRandom.uuid,
                        output_text: collected_content
                      )
                    ],
                    function_requests: function_requests
                  )

                  final_chunk = Provider::LlmConcept::ChatStreamChunk.new(
                    type: "response",
                    data: response_data
                  )
                  streamer.call(final_chunk)

                  return response_data
                end
              rescue JSON::ParserError
                Rails.logger.warn ">>> Ollama streaming JSON parse error, skipping line: #{line}"
                # Skip invalid JSON lines
                next
              end
            end
          end
        else
          raise Error, "Ollama streaming error: #{response.code} - #{response.body}"
        end
      end
    end

    def handle_non_streaming_response(payload)
      Rails.logger.info ">>> Ollama handle_non_streaming_response called with payload: #{payload.inspect}"

      uri = URI("#{base_url}/api/chat")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 60
      http.read_timeout = 60

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      Rails.logger.info ">>> Ollama sending request to #{uri} with body: #{request.body}"

      response = http.request(request)

      Rails.logger.info ">>> Ollama received response code: #{response.code}"
      Rails.logger.info ">>> Ollama response body: #{response.body}"

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        content = data.dig("message", "content") || ""

        Rails.logger.info ">>> Ollama extracted content: '#{content}'"
        Rails.logger.info ">>> Ollama content length: #{content.length}"
        Rails.logger.info ">>> Ollama content blank?: #{content.blank?}"

        chat_response = Provider::LlmConcept::ChatResponse.new(
          id: SecureRandom.uuid,
          model: payload[:model],
          messages: [
            Provider::LlmConcept::ChatMessage.new(
              id: SecureRandom.uuid,
              output_text: content
            )
          ],
          function_requests: []
        )

        Rails.logger.info ">>> Ollama created ChatResponse with #{chat_response.messages.size} messages"
        Rails.logger.info ">>> Ollama first message output_text: '#{chat_response.messages.first.output_text}'"

        chat_response
      else
        raise Error, "Ollama API error: #{response.code} - #{response.body}"
      end
    end
end
