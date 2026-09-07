# frozen_string_literal: true

require "apnotic"
require "base64"
require "stringio"

module Apns
  class Client
    REQUIRED_ENV_KEYS = %w[APNS_KEY_ID APNS_TEAM_ID APNS_BUNDLE_ID APNS_PRIVATE_KEY_BASE64].freeze

    def self.configured?
      REQUIRED_ENV_KEYS.all? { |key| ENV[key].present? }
    end

    def initialize(environment:)
      @environment = environment.to_sym
    end

    def deliver(token:, title:, body:, insight_id:)
      raise "APNs credentials are not configured" unless self.class.configured?

      connection = build_connection
      notification = Apnotic::Notification.new(token)
      notification.alert = { title: title, body: body }
      notification.sound = "default"
      notification.topic = ENV.fetch("APNS_BUNDLE_ID")
      notification.push_type = "alert"
      notification.apns_collapse_id = "insight-#{insight_id}"
      notification.custom_payload = { insight_id: insight_id, destination: "insights" }

      connection.push(notification).tap do |response|
        raise "APNs request timed out" unless response
      end
    ensure
      connection&.close
    end

    private
      def build_connection
        options = {
          auth_method: :token,
          cert_path: StringIO.new(Base64.strict_decode64(ENV.fetch("APNS_PRIVATE_KEY_BASE64"))),
          key_id: ENV.fetch("APNS_KEY_ID"),
          team_id: ENV.fetch("APNS_TEAM_ID")
        }

        @environment == :sandbox ? Apnotic::Connection.development(options) : Apnotic::Connection.new(options)
      end
  end
end
