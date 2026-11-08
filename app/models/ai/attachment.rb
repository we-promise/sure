# A file sent with a request: a PDF, or a page image rendered from one. The bytes
# go to the provider inline and never into a `.ai` event, which records the name and size.
Ai::Attachment = Data.define(:filename, :content_type, :data) do
  def self.pdf(data, filename: "document.pdf") = new(filename:, content_type: "application/pdf", data:)
  def self.png(data, filename:) = new(filename:, content_type: "image/png", data:)

  def image? = content_type.to_s.start_with?("image/")
  def pdf? = content_type == "application/pdf"
  def bytes = data.bytesize

  # What a model needs to read it.
  def capability = pdf? ? :documents : :vision

  def to_event = { filename:, bytes: }

  def inspect = "#<Ai::Attachment #{filename} #{content_type} #{bytes} bytes>"
  alias_method :to_s, :inspect
end
