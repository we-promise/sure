require "base64"
require "digest"
require "openssl"
require "uri"

# Browser subscriptions have a separate lifecycle and credentials from native APNs.
class WebPushSubscription < ApplicationRecord
  include Encryptable

  belongs_to :user
  belongs_to :session
  has_many :web_push_deliveries, dependent: :destroy

  if encryption_ready?
    encrypts :endpoint, :p256dh, :auth
  end

  before_validation :set_endpoint_digest
  validates :endpoint, presence: true, length: { maximum: 4096 }
  validates :endpoint_digest, presence: true
  validates :p256dh, presence: true, length: { maximum: 88 }
  validates :auth, presence: true, length: { maximum: 24 }
  validate :validate_destination
  validate :validate_keys
  validate :validate_session_owner

  # An endpoint alone is not ownership proof. Moving a browser between accounts
  # or sessions requires both original subscription keys and gets a new row ID,
  # so queued sends and delayed deletes cannot target the replacement.
  def self.register_for!(user:, session:, endpoint:, p256dh:, auth:)
    candidate = new(user: user, session: session, endpoint: endpoint, p256dh: p256dh, auth: auth)
    candidate.validate!

    attempts = 0
    begin
      transaction(requires_new: true) do
        existing = lock.find_by(endpoint_digest: candidate.endpoint_digest)
        if existing && (existing.user_id != user.id || existing.session_id != session.id)
          unless existing.matches_keys?(p256dh, auth)
            candidate.errors.add(:base, :taken)
            raise ActiveRecord::RecordInvalid, candidate
          end
          existing.destroy!
          existing = nil
        end
        registration = existing || candidate
        registration.assign_attributes(p256dh: p256dh, auth: auth)
        registration.save!
        registration
      end
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 2
      raise
    end
  end

  def self.allowed_endpoint?(endpoint)
    return false unless endpoint.is_a?(String) && endpoint.bytesize <= 4096
    return false unless endpoint.ascii_only? && !endpoint.match?(/[\s\\]/)

    uri = URI.parse(endpoint)
    return false unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil?

    host = uri.host.to_s.downcase
    host == "fcm.googleapis.com" || host == "updates.push.services.mozilla.com" ||
      host.match?(/\A[a-z0-9-]+(?:\.[a-z0-9-]+)*\.push\.apple\.com\z/) ||
      host.match?(/\A[a-z0-9-]+(?:\.[a-z0-9-]+)*\.notify\.windows\.com\z/)
  rescue URI::InvalidURIError
    false
  end

  def matches_keys?(public_key, secret)
    ActiveSupport::SecurityUtils.secure_compare(p256dh, public_key) &&
      ActiveSupport::SecurityUtils.secure_compare(auth, secret)
  end

  def eligible?
    user.active? && session.user_id == user_id && !session.expired?
  end

  def eligible_for?(insight)
    return false unless eligible? && user.preview_features_enabled?
    return false unless insight.family_id == user.family_id && insight.active?
    return false unless Insight.about_shared_accounts.exists?(insight.id)
    return false if insight.insight_type == "budget_on_track"

    if insight.insight_type == "budget_at_risk"
      user.web_push_budget_warnings_enabled? && (insight.priority_high? || insight.priority_medium?)
    else
      insight.priority_high?
    end
  end

  private
    def set_endpoint_digest
      self.endpoint_digest = Digest::SHA256.hexdigest(endpoint.to_s)
    end

    def validate_destination
      errors.add(:endpoint, :invalid) unless self.class.allowed_endpoint?(endpoint)
    end

    def validate_session_owner
      errors.add(:session, :invalid) unless session && user && session.user_id == user.id && !session.expired? && user.active?
    end

    def decode_key(value, length)
      return unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+={0,2}\z/)
      decoded = Base64.urlsafe_decode64(value)
      return unless decoded.bytesize == length
      return unless Base64.urlsafe_encode64(decoded, padding: false) == value.delete_suffix("==").delete_suffix("=")
      decoded
    rescue ArgumentError
      nil
    end

    def validate_keys
      public_key = decode_key(p256dh, 65)
      secret = decode_key(auth, 16)
      errors.add(:auth, :invalid) unless secret
      unless public_key && public_key.getbyte(0) == 4
        errors.add(:p256dh, :invalid)
        return
      end
      group = OpenSSL::PKey::EC::Group.new("prime256v1")
      point = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(public_key, 2))
      errors.add(:p256dh, :invalid) unless point.on_curve? && !point.infinity?
    rescue OpenSSL::OpenSSLError, ArgumentError
      errors.add(:p256dh, :invalid)
    end
end
