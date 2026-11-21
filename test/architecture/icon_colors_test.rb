# frozen_string_literal: true

require "test_helper"

# `icon` maps its `color:` argument through ApplicationHelper::ICON_COLORS. An
# unsupported key resolves to nil and class_names drops it, so the icon renders
# with no colour class and no error is raised. These tests keep the call sites
# and the supported list in step.
class IconColorsTest < ActiveSupport::TestCase
  SOURCE_GLOB = Rails.root.join("app/**/*.{erb,rb}").to_s
  # Guards against a regex that silently stops matching: the suite is only
  # meaningful if it still finds the call sites it is meant to police.
  MINIMUM_COLORED_CALL_SITES = 100

  test "every icon call site passes a supported color" do
    violations = []
    colored_call_sites = 0

    Dir.glob(SOURCE_GLOB).sort.each do |path|
      File.read(path, encoding: "UTF-8").scan(/\bicon[ (]([^%>]{0,400}?)(?:%>|\n)/m) do |arguments|
        arguments.first.scan(/color: *"([a-z0-9-]+)"/) do |color|
          colored_call_sites += 1
          key = color.first
          next if ApplicationHelper::ICON_COLORS.key?(key.to_sym)

          violations << "#{path.delete_prefix("#{Rails.root}/")}: color: \"#{key}\""
        end
      end
    end

    assert_operator colored_call_sites, :>=, MINIMUM_COLORED_CALL_SITES,
      "only found #{colored_call_sites} icon call sites with a color; the scan is probably broken"

    assert_empty violations,
      "icon colors must be one of #{ApplicationHelper::ICON_COLORS.keys.join(", ")}:\n#{violations.join("\n")}"
  end

  test "every supported color resolves to a functional token" do
    ApplicationHelper::ICON_COLORS.each_value do |token|
      assert_match(/\Atext-(secondary|inverse|success|warning|destructive|info|current)\z/, token,
        "#{token} is not a functional design-system token")
    end
  end
end
