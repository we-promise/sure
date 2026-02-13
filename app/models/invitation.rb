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
      # If user is switching families and they are the only user in their old family,
      # preserve their old family by updating their email with a family suffix
      if user.family_id != family_id && user.family.users.count == 1
        preserve_old_family(user)
      end
      
      user.update!(family_id: family_id, role: role.to_s)
      update!(accepted_at: Time.current)
    end
    true
  end

  private

    def preserve_old_family(user)
      old_family = user.family
      return unless old_family

      # Create a modified email to preserve the old family data
      # The format is: originalname+family123@domain.com
      old_email_parts = user.email.split("@")
      preserved_email = "#{old_email_parts[0]}+family#{old_family.id}@#{old_email_parts[1]}"
      
      # Create a new user in the old family with the preserved email
      # This keeps the family alive and accessible
      preserved_user = User.new(
        email: preserved_email,
        family_id: old_family.id,
        role: user.role,
        first_name: user.first_name,
        last_name: user.last_name,
        password: SecureRandom.hex(32), # Random password they can't use
        active: true
      )
      
      # Skip password validation for this special preservation user
      preserved_user.skip_password_validation = true
      preserved_user.save!
    end

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
