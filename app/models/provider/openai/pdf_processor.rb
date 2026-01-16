class Provider::Openai::PdfProcessor
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :pdf_content, :custom_provider, :langfuse_trace, :family

  def initialize(client, model: "", pdf_content: nil, custom_provider: false, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def process
    span = langfuse_trace&.span(name: "process_pdf_api_call", input: {
      model: model.presence || Provider::Openai::DEFAULT_MODEL,
      pdf_size: pdf_content&.bytesize
    })

    response = if custom_provider
      process_generic
    else
      process_native
    end

    span&.end(output: response.to_h)
    response
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    raise
  end

  def instructions
    <<~INSTRUCTIONS.strip_heredoc
      You are a financial document analysis assistant. Your job is to analyze uploaded PDF documents
      and provide a structured summary of what the document contains.

      For each document, you must determine:

      1. **Document Type**: Classify the document as one of the following:
         - `bank_statement`: A bank account statement showing transactions, balances, and account activity
         - `credit_card_statement`: A credit card statement showing charges, payments, and balances
         - `investment_statement`: An investment/brokerage statement showing holdings, trades, or portfolio performance
         - `financial_document`: General financial documents like tax forms, receipts, invoices, or financial reports
         - `contract`: Legal agreements, loan documents, terms of service, or policy documents
         - `other`: Any document that doesn't fit the above categories

      2. **Summary**: Provide a concise summary of the document that includes:
         - The issuing institution or company name (if identifiable)
         - The date range or statement period (if applicable)
         - Key financial figures (account balances, total transactions, etc.)
         - The account holder's name (if visible, use "Account Holder" if redacted)
         - Any notable items or important information

      3. **Extracted Data**: If the document is a statement with transactions, extract key metadata:
         - Number of transactions (if countable)
         - Statement period (start and end dates)
         - Opening and closing balances (if visible)
         - Currency used

      IMPORTANT GUIDELINES:
      - Be factual and precise - only report what you can clearly see in the document
      - If information is unclear or redacted, note it as "not clearly visible" or "redacted"
      - Do NOT make assumptions about data you cannot see
      - For statements with many transactions, provide a count rather than listing each one
      - Focus on providing actionable information that helps the user understand what they uploaded
      - If the document is unreadable or the PDF is corrupted, indicate this clearly

      Respond with ONLY valid JSON in this exact format (no markdown code blocks, no other text):
      {
        "document_type": "bank_statement|credit_card_statement|investment_statement|financial_document|contract|other",
        "summary": "A clear, concise summary of the document contents...",
        "extracted_data": {
          "institution_name": "Name of bank/company or null",
          "statement_period_start": "YYYY-MM-DD or null",
          "statement_period_end": "YYYY-MM-DD or null",
          "transaction_count": number or null,
          "opening_balance": number or null,
          "closing_balance": number or null,
          "currency": "USD/EUR/etc or null",
          "account_holder": "Name or null"
        }
      }
    INSTRUCTIONS
  end

  private

  PdfProcessingResult = Provider::LlmConcept::PdfProcessingResult

  def process_native
    effective_model = model.presence || Provider::Openai::DEFAULT_MODEL

    # Encode PDF content as base64 for the API
    pdf_base64 = Base64.strict_encode64(pdf_content)

    response = client.responses.create(parameters: {
      model: effective_model,
      input: [
        {
          role: "user",
          content: [
            {
              type: "file",
              file: {
                filename: "document.pdf",
                file_data: "data:application/pdf;base64,#{pdf_base64}"
              }
            },
            {
              type: "text",
              text: "Please analyze this PDF document and provide a structured summary."
            }
          ]
        }
      ],
      instructions: instructions,
      text: {
        format: {
          type: "json_schema",
          name: "pdf_analysis_result",
          strict: true,
          schema: json_schema
        }
      }
    })

    Rails.logger.info("Tokens used to process PDF: #{response.dig("usage", "total_tokens")}")

    record_usage(
      effective_model,
      response.dig("usage"),
      operation: "process_pdf",
      metadata: { pdf_size: pdf_content&.bytesize }
    )

    parse_response_native(response)
  end

  def process_generic
    effective_model = model.presence || Provider::Openai::DEFAULT_MODEL

    # Encode PDF content as base64 for the API
    pdf_base64 = Base64.strict_encode64(pdf_content)

    params = {
      model: effective_model,
      messages: [
        { role: "system", content: instructions },
        {
          role: "user",
          content: [
            {
              type: "file",
              file: {
                filename: "document.pdf",
                file_data: "data:application/pdf;base64,#{pdf_base64}"
              }
            },
            {
              type: "text",
              text: "Please analyze this PDF document and provide a structured summary."
            }
          ]
        }
      ]
    }

    response = client.chat(parameters: params)

    Rails.logger.info("Tokens used to process PDF: #{response.dig("usage", "total_tokens")}")

    record_usage(
      effective_model,
      response.dig("usage"),
      operation: "process_pdf",
      metadata: { pdf_size: pdf_content&.bytesize }
    )

    parse_response_generic(response)
  end

  def parse_response_native(response)
    message_output = response["output"]&.find { |o| o["type"] == "message" }
    raw = message_output&.dig("content", 0, "text")

    raise Provider::Openai::Error, "No message content found in response" if raw.nil?

    build_result(JSON.parse(raw))
  rescue JSON::ParserError => e
    raise Provider::Openai::Error, "Invalid JSON in PDF processing response: #{e.message}"
  end

  def parse_response_generic(response)
    raw = response.dig("choices", 0, "message", "content")
    parsed = parse_json_flexibly(raw)

    build_result(parsed)
  end

  def build_result(parsed)
    PdfProcessingResult.new(
      summary: parsed["summary"],
      document_type: normalize_document_type(parsed["document_type"]),
      extracted_data: parsed["extracted_data"] || {}
    )
  end

  def normalize_document_type(doc_type)
    return "other" if doc_type.blank?

    normalized = doc_type.to_s.strip.downcase.gsub(/\s+/, "_")
    Import::DOCUMENT_TYPES.include?(normalized) ? normalized : "other"
  end

  def parse_json_flexibly(raw)
    return {} if raw.blank?

    # Try direct parse first
    JSON.parse(raw)
  rescue JSON::ParserError
    # Try to extract JSON from markdown code blocks
    if raw =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
      begin
        return JSON.parse($1)
      rescue JSON::ParserError
        # Continue to next strategy
      end
    end

    # Try to find any JSON object
    if raw =~ /(\{[\s\S]*\})/m
      begin
        return JSON.parse($1)
      rescue JSON::ParserError
        # Fall through to error
      end
    end

    raise Provider::Openai::Error, "Could not parse JSON from PDF processing response: #{raw.truncate(200)}"
  end

  def json_schema
    {
      type: "object",
      properties: {
        document_type: {
          type: "string",
          enum: Import::DOCUMENT_TYPES,
          description: "The type of financial document"
        },
        summary: {
          type: "string",
          description: "A concise summary of the document contents"
        },
        extracted_data: {
          type: "object",
          properties: {
            institution_name: {
              type: [ "string", "null" ],
              description: "Name of the issuing institution"
            },
            statement_period_start: {
              type: [ "string", "null" ],
              description: "Start date of statement period (YYYY-MM-DD)"
            },
            statement_period_end: {
              type: [ "string", "null" ],
              description: "End date of statement period (YYYY-MM-DD)"
            },
            transaction_count: {
              type: [ "integer", "null" ],
              description: "Number of transactions in the statement"
            },
            opening_balance: {
              type: [ "number", "null" ],
              description: "Opening balance amount"
            },
            closing_balance: {
              type: [ "number", "null" ],
              description: "Closing balance amount"
            },
            currency: {
              type: [ "string", "null" ],
              description: "Currency code (e.g., USD, EUR)"
            },
            account_holder: {
              type: [ "string", "null" ],
              description: "Name of the account holder"
            }
          },
          required: [
            "institution_name",
            "statement_period_start",
            "statement_period_end",
            "transaction_count",
            "opening_balance",
            "closing_balance",
            "currency",
            "account_holder"
          ],
          additionalProperties: false
        }
      },
      required: [ "document_type", "summary", "extracted_data" ],
      additionalProperties: false
    }
  end
end
