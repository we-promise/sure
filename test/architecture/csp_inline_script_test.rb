# frozen_string_literal: true

require "test_helper"

# The Content-Security-Policy (config/initializers/content_security_policy.rb)
# only runs inline scripts that carry the request nonce. Inline event handlers
# and javascript: URLs can never carry one, so the browser silently drops them.
# This test catches them before they ship.
class CspInlineScriptTest < ActiveSupport::TestCase
  TEMPLATE_GLOBS = %w[app/views/**/*.erb app/components/**/*.erb app/components/**/*.rb app/helpers/**/*.rb].freeze

  EVENTS = %w[
    abort animationend beforeunload blur change click contextmenu copy cut dblclick drag dragend dragover
    dragstart drop error focus focusin focusout input invalid keydown keypress keyup load mousedown
    mouseenter mouseleave mousemove mouseout mouseover mouseup paste pointerdown pointerup reset resize
    scroll select submit toggle touchend touchmove touchstart transitionend unload wheel
  ].freeze
  EVENT = "on(?:#{EVENTS.join("|")})"

  # onclick="…" in markup, or onclick: … / "onclick" => … in tag helpers.
  INLINE_HANDLER = /(?:\s#{EVENT}\s*=\s*["']|["']?\b#{EVENT}["']?\s*(?::(?!:)|=>))/i
  JAVASCRIPT_URL = /["']\s*javascript:/i
  SCRIPT_TAG = /<script\b([^>]*)>.*?<\/script>/mi
  DATA_SCRIPT_TYPE = /type\s*=\s*["']application\/(?:ld\+)?json["']/i

  test "templates have no inline event handlers" do
    assert_no_offenses(INLINE_HANDLER, "inline event handler (use a Stimulus action instead)")
  end

  test "templates have no javascript: URLs" do
    assert_no_offenses(JAVASCRIPT_URL, "javascript: URL (use a Stimulus action instead)")
  end

  test "inline script tags carry the CSP nonce" do
    offenses = template_sources.flat_map do |path, source|
      source.to_enum(:scan, SCRIPT_TAG).filter_map do
        attributes = Regexp.last_match(1)
        next if attributes.match?(/\b(?:nonce|src)\s*=/i) || attributes.match?(DATA_SCRIPT_TYPE)

        "#{path}:#{line_of(source, Regexp.last_match.begin(0))}"
      end
    end

    assert_empty offenses, "inline <script> without nonce=\"<%= content_security_policy_nonce %>\":\n#{offenses.join("\n")}"
  end

  test "the checks catch what they are meant to catch" do
    assert_match INLINE_HANDLER, %(<img src="x" onerror="this.remove()">)
    assert_match INLINE_HANDLER, %(image_tag url, onerror: "this.remove()")
    assert_match INLINE_HANDLER, %(image_tag url, onerror: on_error)
    assert_match INLINE_HANDLER, %(tag.button "Go", "onclick" => "go()")
    assert_no_match INLINE_HANDLER, %(data: { action: "click->menu#toggle" }, onboarding: "x")
    assert_match JAVASCRIPT_URL, %(<a href="javascript:void(0)">)
    assert_match SCRIPT_TAG, %(<script>alert(1)</script>)
  end

  private
    def assert_no_offenses(pattern, description)
      offenses = template_sources.flat_map do |path, source|
        source.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}" if line.match?(pattern) }
      end

      assert_empty offenses, "#{description}:\n#{offenses.join("\n")}"
    end

    # ERB and HTML comments are dropped (kept as blank lines so line numbers
    # stay right); they may mention <script> or onerror in prose.
    def template_sources
      @template_sources ||= TEMPLATE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob)] }.sort.to_h do |file|
        source = File.read(file).gsub(/<%#.*?%>|<!--.*?-->/m) { |comment| "\n" * comment.count("\n") }
        [ Pathname(file).relative_path_from(Rails.root).to_s, source ]
      end
    end

    def line_of(source, offset)
      source[0...offset].count("\n") + 1
    end
end
