# frozen_string_literal: true

require "test_helper"

class ApiCurrentUsageTest < ActiveSupport::TestCase
  API_CONTROLLER_GLOB = Rails.root.join("app/controllers/api/**/*.rb").to_s
  BASE_CONTROLLER = Rails.root.join("app/controllers/api/v1/base_controller.rb").to_s
  DISALLOWED_CURRENT_REFERENCES = [
    "Current.user",
    "Current.family",
    "Current.session"
  ].freeze

  # Api::V1::BaseController may set an unsaved session as a compatibility bridge
  # for code paths that still derive Current.user from Current.session.user.
  # Add new entries only when they are part of that bridge and document why.
  ALLOWED_BASE_CONTROLLER_REFERENCES = [
    "Current.session = @current_user.sessions.build(",
    "Current.session.active_impersonator_session = nil"
  ].freeze

  test "api controllers scope through current_resource_owner instead of Current" do
    violations = []

    Dir.glob(API_CONTROLLER_GLOB).sort.each do |path|
      File.readlines(path).each.with_index(1) do |line, line_number|
        next unless DISALLOWED_CURRENT_REFERENCES.any? { |reference| line.include?(reference) }
        next if allowed_base_controller_reference?(path, line)

        relative_path = Pathname.new(path).relative_path_from(Rails.root)
        violations << "#{relative_path}:#{line_number}: #{line.strip}"
      end
    end

    assert_empty violations, <<~MESSAGE
      API controllers should not read Current.user, Current.family, or Current.session.

      Use current_resource_owner/current_resource_owner.family for API auth scoping.
      The only allowed Current.session usage is the compatibility bridge in Api::V1::BaseController.

      #{violations.join("\n")}
    MESSAGE
  end

  private
    def allowed_base_controller_reference?(path, line)
      path == BASE_CONTROLLER && ALLOWED_BASE_CONTROLLER_REFERENCES.any? { |reference| line.include?(reference) }
    end
end
