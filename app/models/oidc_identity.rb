class OidcIdentity < ApplicationRecord
  belongs_to :user

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }
  validates :user_id, presence: true

  # Update the last authenticated timestamp
  def record_authentication!
    update!(last_authenticated_at: Time.current)
  end

  # Extract and store relevant info from OmniAuth auth hash
  def self.create_from_omniauth(auth, user)
    create!(
      user: user,
      provider: auth.provider,
      uid: auth.uid,
      info: {
        email: auth.info&.email,
        name: auth.info&.name,
        first_name: auth.info&.first_name,
        last_name: auth.info&.last_name
      },
      last_authenticated_at: Time.current
    )
  end
end
