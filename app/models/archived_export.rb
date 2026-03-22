class ArchivedExport < ApplicationRecord
  has_one_attached :export_file, dependent: :purge_later

  scope :expired, -> { where(expires_at: ...Time.current) }

  attr_reader :download_token

  before_create :set_download_token_digest

  def downloadable?
    expires_at > Time.current && export_file.attached?
  end

  def self.find_by_download_token!(token)
    find_by!(download_token_digest: digest_token(token))
  end

  def self.digest_token(token)
    OpenSSL::Digest::SHA256.hexdigest(token)
  end

  private

    def set_download_token_digest
      raw_token = SecureRandom.urlsafe_base64(24)
      @download_token = raw_token
      self.download_token_digest = self.class.digest_token(raw_token)
    end
end
