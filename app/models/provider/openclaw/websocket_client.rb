class Provider::Openclaw::WebsocketClient
  Error = Class.new(StandardError)
  ConnectionError = Class.new(Error)
  TimeoutError = Class.new(Error)

  def initialize(gateway_url:, connection_timeout: 10, response_timeout: 120)
    @gateway_url = gateway_url
    @connection_timeout = connection_timeout
    @response_timeout = response_timeout
  end

  def available?
    send_command("/status").present?
  rescue => e
    Rails.logger.debug("OpenClaw availability check failed: #{e.message}")
    false
  end

  def send_message(content, functions: [], streamer: nil)
    response_data = nil
    error = nil
    received_complete = false

    begin
      ws = create_connection

      ws.on :message do |msg|
        parsed = parse_message(msg.data)
        next unless parsed

        if streamer && parsed[:type] == "text_delta"
          streamer.call(build_text_chunk(parsed[:content]))
        elsif parsed[:type] == "complete"
          response_data = parsed[:response]
          received_complete = true
        elsif parsed[:type] == "error"
          error = Error.new(parsed[:message])
        end
      end

      ws.on :error do |e|
        error = ConnectionError.new("WebSocket error: #{e.message}")
      end

      ws.on :open do
        payload = build_message_payload(content, functions: functions)
        ws.send(payload.to_json)
      end

      deadline = Time.current + @response_timeout
      until received_complete || error || Time.current > deadline
        sleep 0.1
      end

      ws.close if ws.open?

      raise TimeoutError, "Response timeout after #{@response_timeout}s" if !received_complete && !error
      raise error if error

      if streamer && response_data
        streamer.call(build_response_chunk(response_data))
      end

      response_data
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise ConnectionError, "Failed to connect to OpenClaw gateway at #{@gateway_url}: #{e.message}"
    end
  end

  def send_command(command)
    send_message(command)
  end

  private
    attr_reader :gateway_url, :connection_timeout, :response_timeout

    def create_connection
      require "websocket-client-simple"
      WebSocket::Client::Simple.connect(gateway_url, { connect_timeout: connection_timeout })
    end

    def parse_message(data)
      parsed = JSON.parse(data)

      case parsed["type"]
      when "text", "delta"
        { type: "text_delta", content: parsed["content"] || parsed["text"] }
      when "complete", "response"
        { type: "complete", response: parsed }
      when "error"
        { type: "error", message: parsed["message"] || "Unknown error" }
      when "status"
        { type: "status", data: parsed }
      else
        nil
      end
    rescue JSON::ParserError
      { type: "text_delta", content: data }
    end

    def build_message_payload(content, functions: [])
      payload = { message: content }

      if functions.any?
        payload[:tools] = functions.map do |fn|
          {
            type: "function",
            function: {
              name: fn[:name],
              description: fn[:description],
              parameters: fn[:params_schema]
            }
          }
        end
      end

      payload
    end

    def build_text_chunk(content)
      Provider::LlmConcept::ChatStreamChunk.new(
        type: "output_text",
        data: content,
        usage: nil
      )
    end

    def build_response_chunk(response_data)
      Provider::LlmConcept::ChatStreamChunk.new(
        type: "response",
        data: response_data,
        usage: response_data["usage"]
      )
    end
end
