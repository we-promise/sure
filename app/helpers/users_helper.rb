module UsersHelper
  # Returns the avatar URL (small variant by default), or nil when optional storage cannot serve it.
  def user_avatar_url(user, variant: :small)
    return unless user.profile_image.attached?

    image = variant ? user.profile_image.variant(variant) : user.profile_image
    image.url
  rescue StandardError => error
    # Avatars are optional: storage configuration, downloads, or processing must
    # not prevent people from using the app. Never log storage URLs or
    # exception messages, which can contain credentials or private object keys.
    Rails.logger.warn("[Users] Avatar unavailable for user_id=#{user.id} (#{error.class})")
    nil
  end
end
