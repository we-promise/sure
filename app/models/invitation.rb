class Invitation < ApplicationRecord
  include Encryptable

  belongs_to :family
  belongs_to :inviter, class_name: "User"

  # Encrypt sensitive fields if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :token, deterministic: true
    encrypts :email, deterministic: true, downcase: true
  end

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: %w[admin member guest] }
  validates :token, presence: true, uniqueness: true
  validates_uniqueness_of :email, scope: :family_id, message: "has already been invited to this family"
  validate :inviter_is_admin

  before_validation :generate_token, on: :create
  before_create :set_expiration

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }

  def pending?
    accepted_at.nil? && expires_at > Time.current
  end

  def accept_for(user)
    return false if user.blank?
    return false unless pending?
    return false unless emails_match?(user)

    transaction do
      user.update!(family_id: family_id, role: role.to_s)
      update!(accepted_at: Time.current)
    end
    true
  end

  private

    def emails_match?(user)
      inv_email = email.to_s.strip.downcase
      usr_email = user.email.to_s.strip.downcase
      inv_email.present? && usr_email.present? && inv_email == usr_email
    end

    def generate_token
      loop do
        self.token = SecureRandom.hex(32)
        break unless self.class.exists?(token: token)
      end
    end

    def set_expiration
      self.expires_at = 3.days.from_now
    end

    def inviter_is_admin
      inviter.admin?
    end
end
