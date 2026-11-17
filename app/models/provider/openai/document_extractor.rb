# Reads structured data out of a PDF by sending its text to a chat model and
# asking for JSON matching the caller's schema.
class Provider::Openai::DocumentExtractor
  include Provider::Openai::Concerns::JsonMode

  MAX_CHARS = 60_000

  attr_reader :client, :model, :pdf_content, :schema, :instructions, :json_mode

  def initialize(client:, model:, pdf_content:, schema:, instructions:, json_mode: nil)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @schema = schema
    @instructions = instructions
    @json_mode = json_mode || default_json_mode
  end

  def extract
    text = pdf_text
    raise Provider::Openai::Error, "Could not extract text from PDF" if text.blank?

    params = {
      model: model,
      messages: [
        { role: "system", content: "#{instructions}\n\nRespond with JSON only, matching this JSON schema:\n#{schema.to_json}" },
        { role: "user", content: text.first(MAX_CHARS) }
      ]
    }
    # The schema travels in the prompt; json_object keeps every model working
    # (strict schemas need every property listed as required).
    apply_json_mode(params, mode: json_mode)

    content = client.chat(parameters: params).dig("choices", 0, "message", "content")
    raise Provider::Openai::Error, "No response from AI" if content.blank?

    JSON.parse(content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip)
  end

  private
    def pdf_text
      PDF::Reader.new(StringIO.new(pdf_content)).pages.map(&:text).join("\n\n")
    rescue => e
      Rails.logger.error("DocumentExtractor: failed to read PDF text: #{e.message}")
      nil
    end
end
