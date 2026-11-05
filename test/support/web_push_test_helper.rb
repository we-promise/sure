require "openssl"
require "base64"

module WebPushTestHelper
  def web_push_attributes(endpoint: "https://fcm.googleapis.com/fcm/send/test-device")
    {
      endpoint: endpoint,
      p256dh: Base64.urlsafe_encode64(OpenSSL::PKey::EC.generate("prime256v1").public_key.to_octet_string(:uncompressed), padding: false),
      auth: Base64.urlsafe_encode64(SecureRandom.random_bytes(16), padding: false)
    }
  end

  def register_web_push(user: users(:family_admin), session: nil, **attributes)
    session ||= user.sessions.create!
    WebPushSubscription.register_for!(user: user, session: session, **web_push_attributes.merge(attributes))
  end

  def enable_web_push_preview(user)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
  end
end
