require "web_push"

# The maintained web-push library owns RFC 8291 encryption and VAPID signing.
# This boundary only validates destinations and classifies sanitized outcomes.
class WebPush::Client
  class TransientError < StandardError; end

  def self.vapid
    {
      public_key: ENV["WEB_PUSH_VAPID_PUBLIC_KEY"],
      private_key: ENV["WEB_PUSH_VAPID_PRIVATE_KEY"],
      subject: ENV["WEB_PUSH_VAPID_SUBJECT"]
    }
  end

  def self.configured?
    values = vapid
    return false unless values.values.all?(&:present?)
    subject = URI.parse(values[:subject])
    contact_email = subject.is_a?(URI::MailTo) && subject.to.to_s.match?(URI::MailTo::EMAIL_REGEXP)
    contact_url = subject.is_a?(URI::HTTPS) && subject.host.present? && subject.userinfo.nil?
    return false unless contact_email || contact_url
    WebPush::VapidKey.from_keys(values[:public_key], values[:private_key]).curve.check_key
  rescue URI::Error, OpenSSL::OpenSSLError, ArgumentError
    false
  end

  def deliver(subscription:, payload:)
    return :rejected unless WebPushSubscription.allowed_endpoint?(subscription.endpoint)

    WebPush.payload_send(
      endpoint: subscription.endpoint, p256dh: subscription.p256dh, auth: subscription.auth,
      message: payload.to_json, vapid: self.class.vapid,
      ttl: 300, urgency: "normal", open_timeout: 5, read_timeout: 10, ssl_timeout: 5
    )
    :accepted
  rescue WebPush::InvalidSubscription, WebPush::ExpiredSubscription
    :gone
  rescue WebPush::TooManyRequests, WebPush::PushServiceError,
      Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, Timeout::Error,
      OpenSSL::SSL::SSLError, SocketError, IOError, SystemCallError
    # Provider exceptions include response bodies, and connection errors may
    # contain the endpoint. Neither belongs in Rails or Sidekiq retry logs.
    raise TransientError, "Browser push delivery temporarily unavailable", cause: nil
  rescue WebPush::Error, OpenSSL::OpenSSLError, ArgumentError
    :rejected
  end
end
