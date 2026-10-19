# Reads the itemized lines off a receipt so a transaction can be split by
# them. Text PDFs (most emailed retailer receipts) are sent as extracted text;
# photos go as native image blocks and PDFs without a text layer (scanned
# receipts) as native document blocks, which Claude reads visually and which
# need a vision-capable model.
class Provider::Anthropic::ReceiptExtractor
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_receipt".freeze
  # Anthropic's image block accepts these media types.
  IMAGE_MEDIA_TYPES = {
    "image/jpeg" => "image/jpeg",
    "image/jpg" => "image/jpeg",
    "image/png" => "image/png",
    "image/gif" => "image/gif",
    "image/webp" => "image/webp"
  }.freeze
  # Anthropic rejects images over 5 MB (measured on the decoded bytes).
  MAX_IMAGE_BYTES = 5 * 1024 * 1024
  MAX_TEXT_CHARS = 30_000

  attr_reader :client, :model, :file_content, :content_type, :langfuse_trace, :family, :vision

  # @param vision [Boolean] whether the model can read images and documents;
  #   without it only text PDFs can be read
  def initialize(client, model:, file_content:, content_type:, langfuse_trace: nil, family: nil, vision: true)
    @client = client
    @model = model
    @file_content = file_content
    @content_type = content_type
    @langfuse_trace = langfuse_trace
    @family = family
    @vision = vision
  end

  def extract
    span = langfuse_trace&.span(name: "extract_receipt_api_call", input: {
      model: model, content_type: content_type, size: file_content&.bytesize
    })

    content, operation = user_content

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: content } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    # The call is billed even when its tool input cannot be parsed, so usage
    # is recorded before parsing and no error row is added after it.
    record_usage(model, response.usage, operation: operation, metadata: { content_type: content_type })
    usage_recorded = true

    result = ReceiptExtraction.from_response(extract_tool_input(response))

    span&.end(output: { line_item_count: result.line_items.size }, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message, error_detail: safe_error_detail(e) }, level: "ERROR")
    unless usage_recorded
      record_usage_error(model, operation: operation || "extract_receipt", error: e, metadata: { content_type: content_type })
    end
    raise
  end

  def instructions
    <<~INSTRUCTIONS.strip
      You read store receipts and invoices and list what was bought.
      Return the result via the #{TOOL_NAME} tool.

      Return every purchased line item with its name and its line total as printed
      (quantity times unit price when both are shown). Do not include subtotal,
      tax, tip, discount, payment, change or balance lines as items.

      Also return, when the receipt shows them:
      - tax: the total tax charged
      - discount: the total of receipt-level discounts and coupons as a positive
        number (a discount printed against one item reduces that item's line total
        instead)
      - total: the amount actually charged
      - merchant_name and currency (ISO 4217 code)

      Use plain numbers without currency symbols. Use null for anything the receipt
      does not show. Do not guess values you cannot read.
    INSTRUCTIONS
  end

  private
    ReceiptExtraction = Provider::LlmConcept::ReceiptExtraction

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    # @return [Array(Array<Hash>, String)] the message content blocks and the
    #   usage operation name
    def user_content
      raise Provider::Anthropic::Error, "Receipt content is required" if file_content.blank?

      if content_type == "application/pdf"
        pdf_content
      elsif IMAGE_MEDIA_TYPES.key?(content_type)
        image_content
      else
        raise Provider::Anthropic::Error, "Unsupported receipt type: #{content_type}"
      end
    end

    def pdf_content
      text = Pdf::TextExtractor.pages(file_content).join("\n\n")

      if text.present?
        [ [ { type: "text", text: "Receipt text:\n\n#{text.truncate(MAX_TEXT_CHARS)}" } ], "extract_receipt" ]
      else
        require_vision!("This receipt PDF has no text layer; reading it")
        if file_content.bytesize > Provider::Anthropic::PdfProcessor::MAX_PDF_BYTES
          raise Provider::Anthropic::Error, "Receipt PDF is too large (#{file_content.bytesize} bytes) for Anthropic's request limit"
        end

        [ [ base64_block("document", "application/pdf"), read_prompt ], "extract_receipt_vision" ]
      end
    end

    def image_content
      require_vision!("Reading a receipt photo")
      if file_content.bytesize > MAX_IMAGE_BYTES
        raise Provider::Anthropic::Error, "Receipt image is too large (#{file_content.bytesize} bytes); Anthropic accepts images up to 5 MB"
      end

      [ [ base64_block("image", IMAGE_MEDIA_TYPES[content_type]), read_prompt ], "extract_receipt_vision" ]
    end

    def require_vision!(what)
      raise Provider::Anthropic::Error, "#{what} needs a vision-capable model" unless vision
    end

    def base64_block(type, media_type)
      { type: type, source: { type: "base64", media_type: media_type, data: Base64.strict_encode64(file_content) } }
    end

    def read_prompt
      { type: "text", text: "Read the attached receipt and return the result via the #{TOOL_NAME} tool." }
    end

    def output_tool
      number_or_null = { type: [ "number", "null" ] }

      {
        name: TOOL_NAME,
        description: "Return the line items, tax, discount and total read off the receipt.",
        input_schema: {
          type: "object",
          properties: {
            merchant_name: { type: [ "string", "null" ] },
            currency: { type: [ "string", "null" ], description: "ISO 4217 code" },
            line_items: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  amount: { type: "number", description: "Line total as printed" }
                },
                required: [ "name", "amount" ],
                additionalProperties: false
              }
            },
            tax: number_or_null,
            discount: number_or_null.merge(description: "Receipt-level discounts as a positive number"),
            total: number_or_null
          },
          required: [ "line_items" ],
          additionalProperties: false
        }
      }
    end

    def extract_tool_input(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input.is_a?(String) ? JSON.parse(input) : input
    rescue JSON::ParserError
      # JSON::ParserError quotes the input, which holds receipt content that
      # must not reach logs or traces.
      raise Provider::Anthropic::Error, "Could not parse #{TOOL_NAME} input from the receipt extraction response"
    end

    def block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def block_input(block)
      block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    end

    def usage_hash(raw_usage)
      return {} unless raw_usage
      {
        "input_tokens" => raw_usage.input_tokens.to_i,
        "output_tokens" => raw_usage.output_tokens.to_i,
        "total_tokens" => raw_usage.input_tokens.to_i + raw_usage.output_tokens.to_i
      }
    end
end
