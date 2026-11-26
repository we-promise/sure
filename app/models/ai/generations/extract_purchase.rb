# What a forwarded order email says: whether it is an order at all, the shop, order number, date,
# total and payment method, the items, each assigned to one of the family's own categories, and
# which attached files are the purchase's receipt or invoice.
#
# Attachments are sent as images, a PDF as its page images (Pdf::PageImages), so any model with
# `vision` reads them; the email's text alone needs no more than structured output.
class Ai::Generations::ExtractPurchase < Ai::Generation
  feature :extract_purchase
  prompt "extract_purchase"
  schema_name "purchase"

  PAYMENT_METHODS = %w[card blik transfer cash cash_on_delivery installments other unknown].freeze

  NULLABLE_STRING = { type: %w[string null] }.freeze
  AMOUNT = { type: %w[number null] }.freeze

  # text: the email as Purchase::EmailText reads it; files: Ai::Attachment images and PDFs, in
  # the order the prompt numbers them; category_names: the family's.
  def initialize(text:, files:, category_names:, family:, user: nil)
    super(family:, user:)
    @text, @files, @category_names = text, files, category_names
  end

  def arguments = { text: @text, files: @files, category_names: @category_names }

  def prompt_locals
    { text: @text, files: @files.map(&:filename), images: attachments.map(&:filename), category_names: @category_names }
  end

  def needs = @files.any? ? %i[vision] : []

  # The family's spelling of the category the model named, ignoring case; nil when none matches.
  def matchers
    names = @category_names.index_by(&:downcase)
    { category_name: ->(name) { names[name.to_s.strip.downcase] } }
  end

  # Each file as images, named after the file's number so the model can name its receipt.
  def attachments
    @attachments ||= @files.each_with_index.flat_map do |file, index|
      number = index + 1
      next [ file.with(filename: "file-#{number}#{File.extname(file.filename)}") ] unless file.pdf?

      pages = Pdf::PageImages.render(file.data, pages: 1..Pdf::PageImages.page_count(file.data))
      pages.each_with_index.map { |png, page| Ai::Attachment.png(png, filename: "file-#{number}-page-#{page + 1}.png") }
    end
  end

  def schema
    {
      type: "object",
      properties: {
        is_order: { type: "boolean", description: "True only for a placed order, or a receipt or invoice of a purchase" },
        not_order_reason: NULLABLE_STRING.merge(description: "When is_order is false, what the email is instead"),
        merchant: NULLABLE_STRING.merge(description: "The shop or marketplace, e.g. Allegro"),
        order_number: NULLABLE_STRING,
        order_date: NULLABLE_STRING.merge(description: "The date the order was placed, YYYY-MM-DD"),
        currency: NULLABLE_STRING.merge(description: "ISO 4217 code"),
        total: AMOUNT.merge(description: "The amount charged for the whole order, all sellers and delivery included"),
        shipping_cost: AMOUNT,
        discount_total: AMOUNT.merge(description: "The sum of order-level discounts as a positive number, 0 when none"),
        payment_method: { type: "string", enum: PAYMENT_METHODS },
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              quantity: AMOUNT,
              unit_price: AMOUNT,
              amount: AMOUNT.merge(description: "The line total for this item"),
              category_name: { type: %w[string null], enum: [ *@category_names, nil ] },
              seller: NULLABLE_STRING.merge(description: "The marketplace seller of this item, if shown")
            },
            required: %w[name quantity unit_price amount category_name seller],
            additionalProperties: false
          }
        },
        # Objects, not bare integers: Ai::Schema keeps only objects in a list.
        receipt_files: {
          type: "array",
          description: "The attached files that are this purchase's receipt or invoice; empty when none",
          items: {
            type: "object",
            properties: { number: { type: "integer", description: "The file's number" } },
            required: %w[number],
            additionalProperties: false
          }
        }
      },
      required: %w[is_order not_order_reason merchant order_number order_date currency total shipping_cost discount_total payment_method
                   items receipt_files],
      additionalProperties: false
    }
  end
end
