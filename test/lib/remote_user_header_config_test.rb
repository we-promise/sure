# frozen_string_literal: true

require "test_helper"

# config/initializers/remote_user_header.rb reads these at boot, but only on an
# instance that actually sets REMOTE_USER_HEADER_EMAIL. The test environment
# doesn't, so the initializer returns early and a conditionally-assigned
# attribute would raise NoMethodError in production while the whole suite stays
# green. Assert the attributes are readable instead.
class RemoteUserHeaderConfigTest < ActiveSupport::TestCase
  STARTUP_ATTRIBUTES = %i[
    remote_user_header_email
    remote_user_trusted_proxies
    remote_user_trusted_proxies_invalid
    remote_user_shared_secret
    remote_user_shared_secret_header
    remote_user_allow_jit
    remote_user_logout_url
    remote_user_logout_url_invalid
  ].freeze

  test "every attribute the startup warning reads is assigned on a default boot" do
    config = Rails.application.config

    STARTUP_ATTRIBUTES.each do |attribute|
      assert_nothing_raised { config.public_send(attribute) }
    end
  end
end
