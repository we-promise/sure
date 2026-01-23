class InviteCode < ApplicationRecord
  include Encryptable

  # Encrypt token if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :token, deterministic: true, downcase: true
  end

  before_validation :generate_token, on: :create

  class << self
    def claim!(token)
      if invite_code = find_by(token: token&.downcase)
        invite_code.destroy!
        true
      end
    end

    def generate!
      create!.token
    end
  end

  private

    def generate_token
      loop do
        self.token = SecureRandom.hex(4)
        break token unless self.class.exists?(token: token)
      end
    end
end
