require "digest"

class PushSubscription < ApplicationRecord
  belongs_to :user
  has_many :push_deliveries, as: :subscription, dependent: :destroy

  enum :environment, { sandbox: "sandbox", production: "production" }, validate: true

  normalizes :token, with: ->(token) { token.downcase }

  # Keep hexadecimal tokens below PostgreSQL's B-tree entry limit for the
  # unique lower(token) index, even when the value cannot be compressed.
  validates :token, presence: true, uniqueness: { case_sensitive: false },
                    length: { maximum: 2048 },
                    format: { with: /\A(?:[0-9a-f]{2})+\z/i }
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

  def eligible?
    user.active? && last_registered_at > 90.days.ago
  end

  def self.channel_ready?
    Apns::Client.available?
  end

  # The APNs adapter for PushDelivery.
  def deliver(delivery)
    PushSubscription::Delivery.new(self).call do |client|
      I18n.with_locale(user.family.locale) do
        client.deliver(token: token, title: I18n.t("insights.notification.title"),
          body: I18n.t("insights.notification.body"), insight_id: delivery.insight_id)
      end
    end
  rescue Apns::Client::TransientError => e
    raise PushDelivery::TransientError, e.message
  end

  # APNs answers 410 with the moment the token stopped being valid. A device
  # that registered again after that moment keeps its row.
  def unregistered_by?(response)
    timestamp = response.body.is_a?(Hash) && response.body["timestamp"]
    return true unless timestamp

    timestamp.is_a?(Numeric) && timestamp.positive? && timestamp.finite? &&
      last_registered_at.to_f * 1000 <= timestamp
  end

  # A response may arrive after the app has registered again: only remove the
  # exact registration sent. Destroy (not delete) so its ledger rows go with it.
  def invalidate_if_unchanged!
    self.class.where(id: id, token: token, environment: environment,
      last_registered_at: last_registered_at).destroy_all
  end
end
