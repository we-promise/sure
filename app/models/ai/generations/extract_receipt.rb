# What a photographed or uploaded receipt, bill or invoice says: the seller, date, total and
# payment method, the VAT lines and the line items, each assigned to one of the family's own
# categories so the receipt can be split without a second call.
#
# Every file is sent as an image: photos as they were normalized on upload, a PDF as its page
# images (Pdf::PageImages), so any model with `vision` can read a receipt, whether or not it reads
# PDFs.
class Ai::Generations::ExtractReceipt < Ai::Generation
  feature :extract_receipt
  prompt "extract_receipt"
  schema_name "receipt"

  DOCUMENT_KINDS = %w[receipt invoice other].freeze
  PAYMENT_METHODS = %w[card cash mixed unknown].freeze
  # Pages of a PDF read at most: a receipt or an invoice, not a statement.
  MAX_PDF_PAGES = 5

  NULLABLE_STRING = { type: %w[string null] }.freeze
  AMOUNT = { type: %w[number null] }.freeze
  DATE = { type: %w[string null], description: "YYYY-MM-DD" }.freeze

  # files: Ai::Attachment images and PDFs of one document; category_names: the family's.
  def initialize(files:, category_names:, family:, user: nil)
    super(family:, user:)
    @files, @category_names = files, category_names
  end

  def arguments = { files: @files, category_names: @category_names }

  def prompt_locals = { files: attachments.size, category_names: @category_names }

  def needs = %i[vision]

  # The family's spelling of the category the model named, ignoring case; nil when none matches.
  def matchers
    names = @category_names.index_by(&:downcase)
    { category_name: ->(name) { names[name.to_s.strip.downcase] } }
  end

  def attachments
    @attachments ||= @files.flat_map do |file|
      next [ file ] unless file.pdf?

      pages = Pdf::PageImages.render(file.data, pages: 1..[ Pdf::PageImages.page_count(file.data), MAX_PDF_PAGES ].min)
      pages.each_with_index.map { |png, index| Ai::Attachment.png(png, filename: "#{File.basename(file.filename, ".*")}-page-#{index + 1}.png") }
    end
  end

  def schema
    {
      type: "object",
      properties: {
        document_kind: { type: "string", enum: DOCUMENT_KINDS },
        merchant: NULLABLE_STRING,
        nip: NULLABLE_STRING.merge(description: "The seller's tax id (NIP), digits only"),
        date: DATE.merge(description: "Sale date (receipt) or issue date (invoice), YYYY-MM-DD"),
        due_date: DATE.merge(description: "Payment due date on invoices and bills, YYYY-MM-DD"),
        total: AMOUNT.merge(description: "The amount paid, e.g. the SUMA PLN line"),
        currency: NULLABLE_STRING.merge(description: "ISO 4217 code"),
        payment_method: { type: "string", enum: PAYMENT_METHODS },
        vat_breakdown: {
          type: "array",
          items: {
            type: "object",
            properties: { letter: NULLABLE_STRING, rate: AMOUNT, net: AMOUNT, vat: AMOUNT, gross: AMOUNT },
            required: %w[letter rate net vat gross],
            additionalProperties: false
          }
        },
        line_items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              quantity: AMOUNT,
              amount: AMOUNT.merge(description: "The line total before the line's discount"),
              discount: AMOUNT.merge(description: "The discount on this line (RABAT) as a positive number, 0 when none"),
              category_name: { type: %w[string null], enum: [ *@category_names, nil ] }
            },
            required: %w[name quantity amount discount category_name],
            additionalProperties: false
          }
        }
      },
      required: %w[document_kind merchant nip date due_date total currency payment_method vat_breakdown line_items],
      additionalProperties: false
    }
  end
end
