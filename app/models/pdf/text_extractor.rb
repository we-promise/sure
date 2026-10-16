# The text of each page of a PDF, in order. Callers decide how to join the
# pages and how to handle a PDF the reader cannot open; errors propagate.
module Pdf::TextExtractor
  def self.pages(content, max_pages: nil)
    pages = PDF::Reader.new(StringIO.new(content.to_s)).pages
    pages = pages.first(max_pages) if max_pages
    pages.map(&:text)
  end
end
