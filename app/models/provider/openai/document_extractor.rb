# Reads structured data out of a PDF by sending its text to a chat model and
# asking for JSON matching the caller's schema.
class Provider::Openai::DocumentExtractor
  include Provider::Openai::Concerns::JsonMode
  include Provider::Openai::Concerns::UsageRecorder

  # Longer documents are refused rather than cut short: a truncated read would
  # replace complete records with partial ones.
  MAX_CHARS = 60_000

  attr_reader :client, :model, :pdf_content, :schema, :instructions, :json_mode, :family, :custom_provider, :operation

  def initialize(client:, model:, pdf_content:, schema:, instructions:, operation:, json_mode: nil, family: nil, custom_provider: false)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @schema = schema
    @instructions = instructions
    @operation = operation
    @json_mode = json_mode || default_json_mode
    @family = family
    @custom_provider = custom_provider
  end

  def extract
    text = pdf_text
    raise Provider::Openai::Error, "Could not extract text from PDF" if text.blank?
    raise Provider::Openai::Error, "Document is too long to read in one request (#{text.length} characters)" if text.length > MAX_CHARS

    params = {
      model: model,
      messages: [
        { role: "system", content: "#{instructions}\n\nRespond with JSON only, matching this JSON schema:\n#{schema.to_json}" },
        { role: "user", content: text }
      ]
    }
    # The schema travels in the prompt; json_object keeps every model working
    # (strict schemas need every property listed as required).
    apply_json_mode(params, mode: json_mode)

    response = client.chat(parameters: params)
    record_usage(model, response["usage"], operation: operation, metadata: { pdf_size: pdf_content.bytesize })

    content = response.dig("choices", 0, "message", "content")
    raise Provider::Openai::Error, "No response from AI" if content.blank?

    JSON.parse(content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip)
  rescue => e
    record_usage_error(model, operation: operation, error: e, metadata: { pdf_size: pdf_content&.bytesize })
    raise
  end

  private
    def pdf_text
      PDF::Reader.new(StringIO.new(pdf_content)).pages.map(&:text).join("\n\n")
    rescue => e
      Rails.logger.error("DocumentExtractor: failed to read PDF text: #{e.message}")
      nil
    end
end
