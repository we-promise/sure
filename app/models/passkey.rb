class Passkey < ApplicationRecord
  belongs_to :user

  validates :external_id, presence: true, uniqueness: true
  validates :public_key, presence: true

  def self.find_by_credential_id(credential_id)
    find_by(external_id: Base64.urlsafe_encode64(credential_id, padding: false))
  end

  def webauthn_credential
    WebAuthn::Credential.from_get(
      id: external_id,
      public_key: public_key,
      sign_count: sign_count
    )
  end

  def update_sign_count!(new_sign_count)
    update!(sign_count: new_sign_count, last_used_at: Time.current)
  end
end
