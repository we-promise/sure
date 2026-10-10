class Provider::Openai::ChatStreamParser
  Error = Class.new(StandardError)

  StreamErrorData = Data.define(:event, :message, :code, :details)

  def initialize(object)
    @object = object
  end

  def parsed
    type = object.dig("type")

    case type
    when "response.output_text.delta", "response.refusal.delta"
      Chunk.new(type: "output_text", data: object.dig("delta"), usage: nil)
    when "response.completed"
      raw_response = object.dig("response")
      usage = raw_response.dig("usage")
      Chunk.new(type: "response", data: parse_response(raw_response), usage: usage)
    when "response.failed"
      Chunk.new(type: "error", data: build_response_error("response.failed"), usage: nil)
    when "response.incomplete"
      Chunk.new(type: "error", data: build_response_error("response.incomplete"), usage: nil)
    when "error"
      Chunk.new(
        type: "error",
        data: StreamErrorData.new(
          event: "error",
          # The Responses API nests the payload under "error" (e.g. rate-limit
          # and quota errors: `{"type"=>"error","error"=>{"message"=>...,
          # "code"=>...}}`). Some OpenAI-compatible endpoints have been seen
          # sending it flat instead, so fall back to the top level before the
          # generic placeholder.
          message: dig_error(object, "message").presence || object.dig("message").presence || "OpenAI stream returned an error event",
          code: dig_error(object, "code") || object.dig("code"),
          details: object
        ),
        usage: nil
      )
    end
  end

  private
    attr_reader :object

    Chunk = Provider::LlmConcept::ChatStreamChunk

    def parse_response(response)
      Provider::Openai::ChatParser.new(response).parsed
    end

    # `Hash#dig` raises if an intermediate value is present but not itself
    # diggable (e.g. "error" sent as a plain string instead of a nested
    # object), so guard against that shape before digging into it.
    def dig_error(hash, key)
      error = hash["error"]
      error.is_a?(Hash) ? error[key] : nil
    end

    def build_response_error(event)
      raw_response = object.dig("response") || {}
      error_message =
        dig_error(raw_response, "message").presence ||
        raw_response.dig("incomplete_details", "reason").presence ||
        "OpenAI stream ended with #{event}"
      code =
        dig_error(raw_response, "code") ||
        raw_response.dig("incomplete_details", "reason")

      StreamErrorData.new(
        event: event,
        message: error_message,
        code: code,
        details: raw_response
      )
    end
end
