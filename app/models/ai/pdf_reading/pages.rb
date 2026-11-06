# What the two `extract_pdf` generations share (section 8.1): they read Ai::PdfReading::Unit
# items, batched by cost, and send each batch as text, page images or the PDF itself.
module Ai::PdfReading::Pages
  extend ActiveSupport::Concern

  included do
    feature :extract_pdf
    batch :units
  end

  attr_reader :content, :filename

  # units: Ai::PdfReading::Unit, all one way; content: the PDF's bytes.
  def initialize(units:, content:, family:, filename: "document.pdf", user: nil)
    super(family:, user:)
    @units, @content, @filename = units, content, filename
  end

  def arguments = { units: @units, content: @content, filename: @filename }

  def way = items.first&.way

  def item_cost(unit) = unit.cost

  def needs = { images: %i[vision], pdf: %i[documents] }.fetch(way, [])

  def prompt_locals
    texts = items.select(&:text?)
    { text: texts.any? ? texts.map { "--- Page #{_1.first_page} ---\n#{_1.text}" }.join("\n\n") : nil, page_label: }
  end

  # Pages are rendered here, for this batch only, by the hardened pdftoppm.
  def attachments
    case way
    when :pdf then [ Ai::Attachment.pdf(content, filename:) ]
    when :images
      pages = items.first.first_page..items.last.last_page
      Pdf::PageImages.render(content, pages:).each_with_index.map do |png, i|
        Ai::Attachment.png(png, filename: "page-#{pages.first + i}.png")
      end
    else []
    end
  end

  private
    def page_label
      first, last = items.first&.first_page, items.last&.last_page
      first == last ? "page #{first}" : "pages #{first}-#{last}"
    end
end
