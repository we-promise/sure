class ArchivedExport < ApplicationRecord
  has_one_attached :export_file, dependent: :purge_later
  has_secure_token :download_token

  scope :expired, -> { where(expires_at: ...Time.current) }

  def downloadable?
    expires_at > Time.current && export_file.attached?
  end
end
