# frozen_string_literal: true

require "apnotic"
require "base64"
require "stringio"

module Apns
  class Client
    REQUIRED_ENV_KEYS = %w[APNS_KEY_ID APNS_TEAM_ID APNS_BUNDLE_ID APNS_PRIVATE_KEY_BASE64].freeze

    UnavailableError = Class.new(StandardError)
    ConfigurationError = Class.new(StandardError)
    TransientError = Class.new(StandardError)

    def self.hosted?
      Rails.application.config.app_mode.managed?
    end

    def self.available?
      hosted? && ENV["APNS_ENABLED"] != "false" && configured?
    end

    def self.configured?
      REQUIRED_ENV_KEYS.all? { |key| ENV[key].present? }
    end

    def initialize(environment:)
      @environment = environment.to_sym
    end

    def deliver(token:, title:, body:, insight_id:)
      push(token: token, title: title, body: body,
        payload: { insight_id: insight_id, destination: "insights" },
        collapse_id: "insight-#{insight_id}", expires_at: 1.hour.from_now)
    end

    def deliver_test(token:, title:, body:, request_id:)
      push(token: token, title: title, body: body,
        payload: { notification_type: "test", destination: "overview" },
        collapse_id: "test-#{request_id}", expires_at: 5.minutes.from_now)
    end

    private

      def push(token:, title:, body:, payload:, collapse_id:, expires_at:)
        raise UnavailableError, "Push delivery is unavailable" unless self.class.available?

        connection = build_connection
        notification = Apnotic::Notification.new(token)
        notification.alert = { title: title, body: body }
        notification.sound = "default"
        notification.topic = ENV.fetch("APNS_BUNDLE_ID")
        notification.push_type = "alert"
        notification.apns_collapse_id = collapse_id
        notification.expiration = expires_at.to_i
        notification.custom_payload = payload

        connection.push(notification, timeout: 10).tap do |response|
          raise TransientError, "APNs request timed out" unless response
        end
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        raise ConfigurationError, "APNs signing configuration is invalid"
      rescue IOError, SystemCallError, Timeout::Error, SocketError, NetHttp2::AsyncRequestTimeout, OpenSSL::SSL::SSLError
        raise TransientError, "APNs connection failed"
      ensure
        connection&.close
      end

      def build_connection
        options = {
          auth_method: :token,
          connect_timeout: 10,
          cert_path: StringIO.new(Base64.strict_decode64(ENV.fetch("APNS_PRIVATE_KEY_BASE64"))),
          key_id: ENV.fetch("APNS_KEY_ID"),
          team_id: ENV.fetch("APNS_TEAM_ID")
        }

        @environment == :sandbox ? Apnotic::Connection.development(options) : Apnotic::Connection.new(options)
      end
  end
end
