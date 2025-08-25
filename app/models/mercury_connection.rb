class MercuryConnection < DirectBankConnection
  validates :credentials, presence: true
  validate :validate_oauth_credentials

  def provider
    @provider ||= Provider::DirectBank::Mercury.new(credentials)
  end

  def refresh_token_if_needed!
    return unless token_expired?

    new_credentials = provider.refresh_access_token
    update!(credentials: credentials.merge(new_credentials))
  rescue Provider::DirectBank::Base::DirectBankError => e
    Rails.logger.error "Failed to refresh Mercury token: #{e.message}"
    update!(status: :requires_update)
    raise
  end

  private

  def validate_oauth_credentials
    return if credentials.blank?

    unless credentials["access_token"].present?
      errors.add(:credentials, "must include access token")
    end
  end

  def token_expired?
    return false unless credentials["expires_at"].present?

    Time.parse(credentials["expires_at"]) <= Time.current + 5.minutes
  rescue
    true
  end
end