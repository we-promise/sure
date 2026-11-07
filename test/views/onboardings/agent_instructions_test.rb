require "test_helper"

class OnboardingAgentInstructionsTest < ActiveSupport::TestCase
  test "instructions use the current HTTPS instance and its MCP routes" do
    document = render_instructions(http_host: "finance.example.test", https: true)
    instructions = document.at_css("textarea").text

    assert_includes instructions, "at https://finance.example.test."
    assert_includes instructions, "MCP client to https://finance.example.test/mcp."
    assert_includes instructions, "Connection settings are at https://finance.example.test/settings/mcp."
    assert_includes instructions, "`sure-cli config set api_url https://finance.example.test`"
    assert_includes instructions, "`brew install we-promise/tap/sure-cli`"
    assert_includes instructions, "Have me run `sure-cli login` in my own terminal"
    assert_includes instructions, "read/write access"
    assert_includes instructions, "checking for duplicates first"
    assert_includes instructions, "Never ask me to paste passwords, API keys, or tokens into chat."
    assert_no_match(/\[instance URL\]|%\{/, instructions)
  end

  test "instructions preserve a custom port and mount path without HTML entities in the copy source" do
    document = render_instructions(http_host: "money.example.test:8443", https: true, script_name: "/household&shared")
    source = document.at_css("textarea[data-onboarding-handoff-target='source']")

    assert_includes source.text, "https://money.example.test:8443/household&shared/mcp"
    assert_includes source.text, "https://money.example.test:8443/household&shared/settings/mcp"
    assert_includes source.text, "`sure-cli config set api_url https://money.example.test:8443/household\\&shared`"
    assert_includes source.text, "\n\nYou can connect"
    assert_includes source.text, "\n\n• MCP:"
    assert_includes source.text, "\n\n• Sure CLI:"
    assert_includes source.text, "\n\nStart by reviewing"
    assert_includes source.text, "\n\nLet me handle"
    assert source.key?("readonly")
    assert_nil source["name"]
    assert_equal "onboarding-handoff#copy", document.at_css("button")["data-action"]
    assert_equal "button", document.at_css("button")["type"]
  end

  test "URL interpolation cannot close the textarea or add markup" do
    mount = "/household</textarea><script>alert(1)</script>"
    document = render_instructions(http_host: "finance.example.test", https: true, script_name: mount)

    assert_equal 1, document.css("textarea").size
    assert_empty document.css("script")
    assert_includes document.at_css("textarea").text, "https://finance.example.test#{mount}/mcp"
  end

  test "the CLI instance URL is a single shell argument even with metacharacters" do
    mount = "/household&shared;$(not-run)'\""
    document = render_instructions(http_host: "finance.example.test:8443", https: true, script_name: mount)
    command = document.at_css("textarea").text[/`(sure-cli config set api_url .*?)`/, 1]

    assert_equal [ "sure-cli", "config", "set", "api_url", "https://finance.example.test:8443#{mount}" ], Shellwords.split(command)
  end

  private
    def render_instructions(**environment)
      html = I18n.with_locale(:en) do
        ApplicationController.renderer.new(environment).render(partial: "onboardings/agent_instructions")
      end

      Nokogiri::HTML.fragment(html)
    end
end
