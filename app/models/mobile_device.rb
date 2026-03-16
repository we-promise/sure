class MobileDevice < ApplicationRecord
  include Encryptable

  # Encrypt device_id if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :device_id, deterministic: true
  end

  belongs_to :user

  validates :device_id, presence: true, uniqueness: { scope: :user_id }
  validates :device_name, presence: true
  validates :device_type, presence: true, inclusion: { in: %w[ios android web] }

  before_validation :set_last_seen_at, on: :create

  CALLBACK_URL = "sureapp://oauth/callback"

  scope :active, -> { where("last_seen_at > ?", 90.days.ago) }

  def self.shared_oauth_application
    @shared_oauth_application ||= begin
      Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |app|
        app.redirect_uri = CALLBACK_URL
        app.scopes = "read_write"
        app.confidential = false
      end
    rescue ActiveRecord::RecordNotUnique
      Doorkeeper::Application.find_by!(name: "Sure Mobile")
    end
  end

  def self.upsert_device!(user, attrs)
    device = user.mobile_devices.find_or_initialize_by(device_id: attrs[:device_id])
    device.assign_attributes(
      device_name: attrs[:device_name],
      device_type: attrs[:device_type],
      os_version: attrs[:os_version],
      app_version: attrs[:app_version],
      last_seen_at: Time.current
    )
    device.save!
    device
  end

  def active?
    last_seen_at > 90.days.ago
  end

  def update_last_seen!
    update_column(:last_seen_at, Time.current)
  end

  def active_tokens
    Doorkeeper::AccessToken
      .where(mobile_device_id: id)
      .where(resource_owner_id: user_id)
      .where(revoked_at: nil)
      .where("expires_in IS NULL OR created_at + expires_in * interval '1 second' > ?", Time.current)
  end

  def revoke_all_tokens!
    active_tokens.update_all(revoked_at: Time.current)
  end

  # Issues a fresh Doorkeeper access token for this device, revoking any
  # previous tokens. Returns a hash with token details ready for an API
  # response or deep-link callback.
  def issue_token!
    revoke_all_tokens!

    access_token = Doorkeeper::AccessToken.create!(
      application: self.class.shared_oauth_application,
      resource_owner_id: user_id,
      mobile_device_id: id,
      expires_in: 30.days.to_i,
      scopes: "read_write",
      use_refresh_token: true
    )

    {
      access_token: access_token.plaintext_token,
      refresh_token: access_token.plaintext_refresh_token,
      token_type: "Bearer",
      expires_in: access_token.expires_in,
      created_at: access_token.created_at.to_i
    }
  end

  private

    def set_last_seen_at
      self.last_seen_at ||= Time.current
    end
end
