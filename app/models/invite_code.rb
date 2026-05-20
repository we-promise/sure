class InviteCode < ApplicationRecord
  include Encryptable

  # Encrypt token if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :token, deterministic: true, downcase: true
  end

  before_validation :generate_token, on: :create

  class << self
    def find_by_token(token)
      find_by(token: token&.downcase)
    end

    def record_signup_attempt!(token)
      find_by_token(token)&.record_signup_attempt!
    end

    def claim!(token)
      find_by_token(token)&.record_successful_signup!
    end

    def generate!
      create!.token
    end
  end

  def record_signup_attempt!
    self.class.increment_counter(:signup_attempts_count, id)
    true
  end

  def record_successful_signup!
    self.class.increment_counter(:successful_signups_count, id)
    true
  end

  private

    def generate_token
      loop do
        self.token = SecureRandom.hex(4)
        break token unless self.class.exists?(token: token)
      end
    end
end
