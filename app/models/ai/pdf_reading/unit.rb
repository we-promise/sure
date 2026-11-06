# One piece of a PDF as a generation reads it (section 8.1): a chunk of text (the text layer or
# an OCR transcription), a range of pages sent as images, or the whole PDF as a file. Ai::Batch
# packs units into requests by their cost, and page images are rendered only for the batch that
# sends them.
Ai::PdfReading::Unit = Data.define(:way, :first_page, :last_page, :text) do
  # What a page image costs a vision model at high detail, about: OpenAI's tiles for a Letter
  # page at 150 dpi come to ~1,100 tokens, Anthropic's ~1,600.
  PAGE_IMAGE_TOKENS = 1_600

  def self.text(text, page:) = new(way: :text, first_page: page, last_page: page, text:)
  def self.page(page) = new(way: :images, first_page: page, last_page: page, text: nil)
  def self.pdf(pages) = new(way: :pdf, first_page: 1, last_page: pages, text: nil)

  def pages = (first_page..last_page)
  def page_count = last_page - first_page + 1
  def text? = !text.nil?

  def cost = text? ? Assistant::TokenEstimator.estimate(text) : PAGE_IMAGE_TOKENS * page_count

  def inspect = "#<Ai::PdfReading::Unit #{way} #{pages}>"
end
