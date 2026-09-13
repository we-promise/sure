class PushSubscription < ApplicationRecord
  belongs_to :user

  enum :environment, { sandbox: "sandbox", production: "production" }, validate: true

  normalizes :token, with: ->(token) { token.downcase }

  # Keep hexadecimal tokens below PostgreSQL's B-tree entry limit for the
  # unique lower(token) index, even when the value cannot be compressed.
  validates :token, presence: true, uniqueness: { case_sensitive: false },
                    length: { maximum: 2048 },
                    format: { with: /\A(?:[0-9a-f]{2})+\z/i }
  validates :platform, inclusion: { in: %w[ios] }
  validates :last_registered_at, presence: true

  scope :recent, -> { where("last_registered_at > ?", 90.days.ago) }

  def eligible?
    user.active? && last_registered_at > 90.days.ago
  end

  # A response may arrive after the app has registered again. Only remove the
  # exact registration sent, and respect APNs' invalidation timestamp when given.
  def invalidate_if_unchanged!(response)
    return unless response.status.to_i == 410

    timestamp = response.body.is_a?(Hash) && response.body["timestamp"]
    if timestamp
      return unless timestamp.is_a?(Numeric) && timestamp.positive? && timestamp.finite?
      return if last_registered_at.to_f * 1000 > timestamp
    end

    self.class.where(id: id, token: token, environment: environment,
      last_registered_at: last_registered_at).delete_all
  end
end
