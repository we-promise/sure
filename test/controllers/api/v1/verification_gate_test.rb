# frozen_string_literal: true

require "test_helper"

class Api::V1::VerificationGateTest < ActionDispatch::IntegrationTest
  ALLOWLIST = {
    "Api::V1::AuthController" => :all,
    "Api::V1::ChatsController" => :all,
    "Api::V1::MessagesController" => :all,
    "Api::V1::UsageController" => :all,
    "Api::V1::TestController" => :all,
    "Api::V1::UsersController" => %w[me destroy]
  }.freeze

  setup do
    @unverified = User.create!(
      email: "unverified-#{SecureRandom.hex(4)}@example.com",
      password: "Password1!",
      family: families(:empty)
    )
    @verified = users(:family_admin)
  end

  test "every non-allowlisted API endpoint refuses unverified users" do
    headers = api_headers(read_write_key_for(@unverified))
    checked = 0

    api_v1_routes.each do |route|
      next if allowlisted?(route[:controller_class], route[:action])

      process route[:verb], route[:path], headers: headers, as: :json
      assert_response :forbidden,
        "#{route[:controller_class]}##{route[:action]} serves unverified users"
      assert_equal "email_verification_required", response.parsed_body["error"]
      checked += 1
    end

    assert_operator checked, :>, 20
  end

  test "gate response tells clients how to recover" do
    get "/api/v1/accounts", headers: api_headers(read_write_key_for(@unverified))

    assert_response :forbidden
    assert_equal "resend_email", response.parsed_body["action"]
  end

  test "verified users pass the gate" do
    get "/api/v1/accounts", headers: api_headers(read_write_key_for(@verified))

    assert_response :success
  end

  private

    def read_write_key_for(user)
      ApiKey.create!(
        user: user,
        name: "Verification gate",
        scopes: [ "read_write" ],
        display_key: "gate_#{SecureRandom.hex(8)}"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def allowlisted?(controller_class, action)
      allowed = ALLOWLIST[controller_class.name]
      allowed == :all || Array(allowed).include?(action)
    end

    def api_v1_routes
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller]
        action = route.defaults[:action]
        next unless controller&.start_with?("api/v1/") && action

        controller_class = "#{controller.camelize}Controller".safe_constantize
        next unless controller_class && controller_class < Api::V1::BaseController

        verb = route.verb.to_s.split("|").first.presence&.downcase
        next unless verb

        path = route.path.spec.to_s.sub("(.:format)", "").gsub(/[:*]\w+/) { SecureRandom.uuid }
        { controller_class: controller_class, action: action, verb: verb.to_sym, path: path }
      end.uniq { |route| [ route[:verb], route[:path].gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, ":id") ] }
    end
end
