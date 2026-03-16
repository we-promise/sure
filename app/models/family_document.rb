class FamilyDocument < ApplicationRecord
  belongs_to :family

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }

  scope :ready, -> { where(status: "ready") }

  def mark_ready!
    update!(status: "ready")
  end

  def mark_error!(error_message = nil)
    update!(status: "error", metadata: (metadata || {}).merge("error" => error_message))
  end

  def supported_extension?
    ext = File.extname(filename).downcase
    SUPPORTED_EXTENSIONS.include?(ext)
  end
end
