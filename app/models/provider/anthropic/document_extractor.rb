# Reads structured data out of a PDF with one forced tool call. The caller
# supplies the tool's JSON schema and instructions; this class only handles the
# request, the usage record and pulling the tool input back out.
class Provider::Anthropic::DocumentExtractor
  include Provider::Anthropic::Concerns::UsageRecorder
  include Provider::Anthropic::Concerns::StructuredOutput

  MAX_PDF_BYTES = 32 * 1024 * 1024

  attr_reader :client, :model, :pdf_content, :tool_name, :schema, :instructions, :family, :max_tokens

  def initialize(client:, model:, pdf_content:, tool_name:, schema:, instructions:, family: nil, max_tokens: 4096)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @tool_name = tool_name
    @schema = schema
    @instructions = instructions
    @family = family
    @max_tokens = max_tokens
  end

  def extract
    raise Provider::Anthropic::Error, "PDF content is required" if pdf_content.blank?
    raise Provider::Anthropic::Error, "PDF exceeds Anthropic's 32 MB limit" if pdf_content.bytesize > MAX_PDF_BYTES

    response = create_structured_message(
      tool_name: tool_name,
      operation: tool_name,
      model: model,
      max_tokens: max_tokens,
      system_: Provider::Anthropic.structured_output_system(instructions, model, tool_name),
      messages: [ { role: "user", content: user_content } ],
      tools: [ { name: tool_name, description: "Return the data read from the document.", input_schema: schema } ],
      tool_choice: Provider::Anthropic.structured_output_tool_choice(model, tool_name)
    )

    tool_use = Array(response.content).find { |block| structured_block_type(block) == :tool_use }
    raise Provider::Anthropic::Error, "Model did not invoke #{tool_name}" unless tool_use

    input = structured_block_input(tool_use)
    input = JSON.parse(input) if input.is_a?(String)
    record_usage(model, response.usage, operation: tool_name, metadata: { pdf_size: pdf_content.bytesize })
    input.deep_stringify_keys
  rescue => e
    record_usage_error(model, operation: tool_name, error: e, metadata: { pdf_size: pdf_content&.bytesize })
    raise
  end

  private
    def user_content
      [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: Base64.strict_encode64(pdf_content) } },
        { type: "text", text: "Read this document and return the result via the #{tool_name} tool." }
      ]
    end
end
