class WebauthnCredential < ApplicationRecord
  belongs_to :user

  before_validation :set_default_nickname

  validates :nickname, presence: true, length: { maximum: 80 }
  validates :credential_id, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :sign_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  private
    def set_default_nickname
      self.nickname = nickname.to_s.strip.presence || I18n.t("webauthn_credentials.default_name")
    end
end
