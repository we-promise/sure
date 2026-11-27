class Ai::Generations::ExtractReceipt < Ai::Generation
  feature :extract_receipt
  prompt "extract_receipt"
  schema_name "receipt"

  schema({
    type: "object",
    properties: {
      merchant_name: { type: %w[string null] }, currency: { type: %w[string null] },
      line_items: { type: "array", items: {
        type: "object", properties: { name: { type: "string" }, amount: { type: "number" } },
        required: %w[name amount], additionalProperties: false
      } },
      tax: { type: %w[number null] }, discount: { type: %w[number null] }, total: { type: %w[number null] }
    },
    required: %w[merchant_name currency line_items tax discount total], additionalProperties: false
  }.freeze)

  def initialize(attachment:, family:, user:)
    super(family:, user:)
    @attachment = attachment
  end

  def prompt_locals = { text: pdf_text.presence }

  def needs = attachments.map(&:capability).uniq

  def attachments
    return [] if pdf_text.present?

    [ Ai::Attachment.new(filename: @attachment.filename.to_s, content_type: @attachment.content_type, data: content) ]
  end

  private
    def content
      @content ||= @attachment.download
    rescue ActiveStorage::FileNotFoundError, IOError, SystemCallError
      raise Ai::Error::InvalidOutput, "The receipt attachment could not be read"
    end

    def pdf_text
      return @pdf_text if defined?(@pdf_text)

      @pdf_text = @attachment.content_type == "application/pdf" ? Pdf::TextExtractor.pages(content).join("\n\n").presence : nil
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
      raise Ai::Error::InvalidOutput, "The receipt PDF could not be read"
    end
end
