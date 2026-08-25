class PushSubscription < ApplicationRecord
  belongs_to :user

  enum :environment, { sandbox: "sandbox", production: "production" }, validate: true

  normalizes :token, with: ->(token) { token.downcase }

  validates :token, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: /\A[0-9a-f]{64,200}\z/i }
  validates :platform, inclusion: { in: %w[ios] }
  validates :last_registered_at, presence: true

  scope :recent, -> { where("last_registered_at > ?", 90.days.ago) }
end
