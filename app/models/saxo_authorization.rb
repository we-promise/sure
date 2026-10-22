class SaxoAuthorization < ApplicationRecord
  belongs_to :family
  belongs_to :user
  belongs_to :saxo_item, optional: true

  validate do
    errors.add(:user, :invalid) if user && user.family_id != family_id
    errors.add(:saxo_item, :invalid) if saxo_item && saxo_item.family_id != family_id
  end

  def self.begin!(user:, item:, redirect_uri:)
    state = SecureRandom.urlsafe_base64(32)
    where("expires_at < ?", Time.current).delete_all
    create!(
      family: user.family,
      user: user,
      saxo_item: item,
      redirect_uri: redirect_uri,
      state_digest: Digest::SHA256.hexdigest(state),
      expires_at: 10.minutes.from_now,
      application_key_digest: Provider::Saxo.application_key_digest
    )
    state
  end

  def self.consume!(state:, user:)
    digest = Digest::SHA256.hexdigest(state.to_s)
    attempt = where(state_digest: digest, user: user, family: user.family).first!
    attempt.with_lock do
      unless attempt.expires_at.future? && attempt.application_key_digest == Provider::Saxo.application_key_digest
        raise Provider::Saxo::AuthenticationError, "Saxo authorization expired"
      end
      attempt.destroy!
    end
    attempt
  end
end
