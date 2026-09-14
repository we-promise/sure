require "digest"

class PushSubscription < ApplicationRecord
  belongs_to :user

  enum :environment, { sandbox: "sandbox", production: "production" }, validate: true

  normalizes :token, with: ->(token) { token.downcase }

  validates :token, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: /\A[0-9a-f]{64,200}\z/i }
  validates :platform, inclusion: { in: %w[ios] }
  validates :last_registered_at, presence: true

  # A per-installation secret proves continuity when the same device changes
  # users while its old subscription could not be removed (for example offline).
  # Never reuse a row ID across users: queued jobs and delayed deletes refer to it.
  def self.register_for!(user:, token:, environment:, platform:, device_key: nil)
    attempts = 0
    begin
      transaction(requires_new: true) do
        subscription = lock.find_by(token: token.downcase)
        candidate = new(user: user, token: token, environment: environment,
          platform: platform, last_registered_at: Time.current)
        if !device_key.nil? && !(device_key.is_a?(String) && device_key.match?(/\A[0-9a-f]{64}\z/))
          candidate.errors.add(:base, "Invalid device key")
          raise ActiveRecord::RecordInvalid, candidate
        end
        digest = Digest::SHA256.hexdigest(device_key) if device_key.present?
        if subscription && subscription.user_id != user.id
          unless digest && subscription.device_key_digest &&
              ActiveSupport::SecurityUtils.secure_compare(subscription.device_key_digest, digest)
            candidate.errors.add(:base, "Device token is already registered")
            raise ActiveRecord::RecordInvalid, candidate
          end
          subscription.destroy!
          subscription = nil
        end
        subscription ||= candidate
        subscription.assign_attributes(environment: environment, platform: platform, last_registered_at: Time.current)
        subscription.device_key_digest = digest if digest
        subscription.save!
        subscription
      end
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 2
      raise
    end
  end

  scope :recent, -> { where("last_registered_at > ?", 90.days.ago) }
end
