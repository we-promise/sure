class Session < ApplicationRecord
  include Encryptable

  # Encrypt user_agent if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :user_agent
  end

  belongs_to :user
  belongs_to :active_impersonator_session,
    -> { where(status: :in_progress) },
    class_name: "ImpersonationSession",
    optional: true

  before_create :capture_session_info

  # ip_address is opaque to queries once encryption is configured, so lookups go
  # through this digest instead. Kept here so callers can't drift from what
  # capture_session_info writes.
  def self.ip_address_digest_for(ip_address)
    return nil if ip_address.blank?

    Digest::SHA256.hexdigest(ip_address.to_s)
  end

  def get_preferred_tab(tab_key)
    data.dig("tab_preferences", tab_key)
  end

  def set_preferred_tab(tab_key, tab_value)
    data["tab_preferences"] ||= {}
    data["tab_preferences"][tab_key] = tab_value
    save!
  end

  private

    def capture_session_info
      self.user_agent = Current.user_agent
      raw_ip = Current.ip_address
      self.ip_address = raw_ip
      self.ip_address_digest = self.class.ip_address_digest_for(raw_ip)
    end
end
