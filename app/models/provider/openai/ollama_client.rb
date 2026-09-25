class Provider::Openai::OllamaClient
  def initialize(base_uri:, access_token:, request_timeout:)
    @url = native_chat_url(base_uri)
    @access_token = access_token
    @request_timeout = request_timeout
  end

  def chat(parameters:)
    response = Faraday.post(@url) do |request|
      request.options.open_timeout = @request_timeout
      request.options.timeout = @request_timeout
      request.headers["Authorization"] = "Bearer #{@access_token}" if @access_token.present?
      request.headers["Content-Type"] = "application/json"
      request.body = request_body(parameters).to_json
    end

    unless response.success?
      raise Provider::Openai::Error, "Ollama returned HTTP #{response.status}: #{response.body.to_s.truncate(500)}"
    end

    native_response = JSON.parse(response.body)
    {
      "choices" => [ {
        "message" => {
          "content" => native_response.dig("message", "content"),
          "thinking" => native_response.dig("message", "thinking")
        }
      } ],
      "usage" => native_response["prompt_eval_count"] || native_response["eval_count"] ? {
        "prompt_tokens" => native_response["prompt_eval_count"],
        "completion_tokens" => native_response["eval_count"],
        "total_tokens" => [ native_response["prompt_eval_count"], native_response["eval_count"] ].compact.sum
      } : {}
    }
  rescue JSON::ParserError => e
    raise Provider::Openai::Error, "Ollama returned invalid JSON: #{e.message}"
  rescue Faraday::Error => e
    raise Provider::Openai::Error, "Ollama request failed: #{e.message}"
  end

  private

    def native_chat_url(base_uri)
      base_uri.to_s.sub(%r{/v1/?\z}, "").sub(%r{/\z}, "") + "/api/chat"
    end

    def request_body(parameters)
      {
        model: parameters[:model],
        messages: normalize_messages(parameters[:messages]),
        stream: false,
        think: false,
        format: "json",
        options: {
          temperature: 0,
          num_predict: parameters[:max_tokens] || 512
        }
      }
    end

    def normalize_messages(messages)
      messages.map do |message|
        content = message[:content] || message["content"]
        if content.is_a?(Array)
          text_parts = content.filter_map do |part|
            part_type = part[:type] || part["type"]
            part[:text] || part["text"] if part_type == "text"
          end
          images = content.filter_map do |part|
            part_type = part[:type] || part["type"]
            next unless part_type == "image_url"

            url = part.dig(:image_url, :url) || part.dig("image_url", "url")
            url&.sub(%r{\Adata:image/[^;]+;base64,}, "")
          end
          { role: message[:role] || message["role"], content: text_parts.join("\n"), images: images }
        else
          { role: message[:role] || message["role"], content: content.to_s }
        end
      end
    end
end
