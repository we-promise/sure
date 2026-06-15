class Provider::Anthropic::PdfProcessor
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_document_analysis".freeze

  # Anthropic enforces a 32 MB limit on the whole Messages *request body*, and
  # the PDF travels base64-encoded (~4/3 larger) inside that body alongside the
  # JSON envelope (instructions, tool schema). So a 32 MB raw PDF would encode
  # to ~42 MB and be rejected. Cap the raw bytes at 3/4 of the request budget,
  # minus a generous envelope reserve, so the encoded request stays under the
  # limit. Guarding upstream also avoids base64-encoding an over-size blob in
  # vain (peak heap before the API would reject it).
  MAX_REQUEST_BYTES = 32 * 1024 * 1024
  REQUEST_ENVELOPE_BYTES = 1 * 1024 * 1024
  MAX_PDF_BYTES = (MAX_REQUEST_BYTES - REQUEST_ENVELOPE_BYTES) * 3 / 4

  attr_reader :client, :model, :pdf_content, :langfuse_trace, :family

  def initialize(client, model:, pdf_content:, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def process
    raise Provider::Anthropic::Error, "PDF content is required" if pdf_content.blank?
    if pdf_content.bytesize > MAX_PDF_BYTES
      raise Provider::Anthropic::Error,
            "PDF is too large (#{pdf_content.bytesize} bytes); base64-encoded it would exceed Anthropic's 32 MB request limit"
    end

    span = langfuse_trace&.span(name: "process_pdf_api_call", input: {
      model: model,
      pdf_size: pdf_content&.bytesize
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_content } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    parsed = extract_tool_input(response)
    result = build_result(parsed)

    record_usage(model, response.usage, operation: "process_pdf", metadata: { pdf_size: pdf_content.bytesize })

    span&.end(output: result.to_h, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "process_pdf", error: e, metadata: { pdf_size: pdf_content&.bytesize })
    raise
  end

  private
    PdfProcessingResult = Provider::LlmConcept::PdfProcessingResult

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def user_content
      [
        {
          type: "document",
          source: {
            type: "base64",
            media_type: "application/pdf",
            data: Base64.strict_encode64(pdf_content)
          }
        },
        {
          type: "text",
          text: "Analyze the attached document and return the result via the report_document_analysis tool."
        }
      ]
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the structured analysis of the attached document.",
        input_schema: {
          type: "object",
          properties: {
            document_type: {
              type: "string",
              enum: Import::DOCUMENT_TYPES,
              description: "Classification of the document."
            },
            summary: {
              type: "string",
              description: "Concise human-readable summary of the document."
            },
            extracted_data: {
              type: "object",
              properties: {
                institution_name: { type: [ "string", "null" ] },
                statement_period_start: { type: [ "string", "null" ], pattern: "^\\d{4}-\\d{2}-\\d{2}$", description: "YYYY-MM-DD or null" },
                statement_period_end: { type: [ "string", "null" ], pattern: "^\\d{4}-\\d{2}-\\d{2}$", description: "YYYY-MM-DD or null" },
                transaction_count: { type: [ "integer", "null" ] },
                opening_balance: { type: [ "number", "null" ] },
                closing_balance: { type: [ "number", "null" ] },
                currency: { type: [ "string", "null" ] },
                account_holder: { type: [ "string", "null" ] }
              },
              required: [],
              additionalProperties: false
            }
          },
          required: [ "document_type", "summary", "extracted_data" ],
          additionalProperties: false
        }
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You analyze financial documents. For the attached PDF, classify the document type,
        summarize it, and extract key metadata. Return the result via the report_document_analysis tool.

        Classification options:
          - bank_statement: bank account statements (incl. mobile money / digital wallets)
          - credit_card_statement: credit card statements
          - investment_statement: brokerage / investment statements
          - financial_document: tax forms, receipts, invoices, financial reports
          - contract: legal agreements, loans, terms of service
          - other: anything else

        Rules:
          - Be factual; only report what is clearly visible
          - If a field is unclear/redacted, return null for it
          - Do not invent figures or names you cannot read
          - For statements with many transactions, return the count rather than enumerating them
      INSTRUCTIONS
    end

    def extract_tool_input(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input
    end

    def build_result(parsed)
      PdfProcessingResult.new(
        summary: parsed["summary"] || parsed[:summary],
        document_type: normalize_document_type(parsed["document_type"] || parsed[:document_type]),
        extracted_data: parsed["extracted_data"] || parsed[:extracted_data] || {}
      )
    end

    def normalize_document_type(doc_type)
      return "other" if doc_type.blank?

      normalized = doc_type.to_s.strip.downcase.gsub(/\s+/, "_")
      Import::DOCUMENT_TYPES.include?(normalized) ? normalized : "other"
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
