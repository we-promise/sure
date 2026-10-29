module Admin::UsersHelper
  # Returns the small avatar URL, or nil when optional storage cannot serve it.
  def admin_user_avatar_url(user)
    user.profile_image.variant(:small).url if user.profile_image.attached?
  rescue StandardError => error
    # Avatars are optional: storage configuration, downloads, or processing must
    # not prevent administrators from managing users. Never log storage URLs or
    # exception messages, which can contain credentials or private object keys.
    Rails.logger.warn("[Admin::Users] Avatar unavailable for user_id=#{user.id} (#{error.class})")
    nil
  end
end
