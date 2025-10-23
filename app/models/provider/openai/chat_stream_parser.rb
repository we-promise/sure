class Provider::Openai::ChatStreamParser
  Error = Class.new(StandardError)

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
    end
  end

  private
    attr_reader :object

    Chunk = Provider::LlmConcept::ChatStreamChunk

    def parse_response(response)
      Provider::Openai::ChatParser.new(response).parsed
    end
end
