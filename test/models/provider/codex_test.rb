require "test_helper"

class Provider::CodexTest < ActiveSupport::TestCase
  test "passes model and reasoning effort to codex exec" do
    provider = Provider::Codex.new(
      command: "/usr/bin/codex",
      model: "gpt-5.6-luna",
      reasoning_effort: "high"
    )

    assert_equal [
      "exec",
      "--ephemeral",
      "--skip-git-repo-check",
      "--sandbox", "read-only",
      "--cd", "/tmp",
      "--ignore-user-config",
      "--output-schema", "/tmp/schema.json",
      "--output-last-message", "/tmp/output.json",
      "--model", "gpt-5.6-luna",
      "--config", 'model_reasoning_effort="high"',
      "--image", "/tmp/page-1.png",
      "-"
    ], provider.send(
      :command_args,
      schema_path: "/tmp/schema.json",
      output_path: "/tmp/output.json",
      image_paths: [ "/tmp/page-1.png" ],
      tmpdir: "/tmp"
    )
  end

  test "omits optional model and reasoning arguments when unset" do
    provider = Provider::Codex.new(command: "/usr/bin/codex", model: nil, reasoning_effort: nil)

    args = provider.send(
      :command_args,
      schema_path: "/tmp/schema.json",
      output_path: "/tmp/output.json",
      image_paths: [],
      tmpdir: "/tmp"
    )

    assert_not_includes args, "--model"
    assert_not_includes args, "--config"
  end

  test "uses the built-in Codex PDF prompt and appends extracted PDF text" do
    provider = Provider::Codex.new(command: "/usr/bin/codex")
    provider.stubs(:extract_text).returns("--- Page 1 ---\nCoffee Shop -12.50")

    prompt = provider.send(:prompt_for, "%PDF", [], family: nil)

    assert_includes prompt, Provider::Codex.default_prompt.strip
    assert_includes prompt, "Coffee Shop -12.50"
    assert_includes prompt, "<pdf_data>"
    assert_includes prompt, "untrusted data"
    assert_includes prompt, "</pdf_data>"
  end

  test "rejects PDFs beyond the page limit" do
    reader = mock
    reader.expects(:page_count).returns(Provider::Codex::MAX_PAGES + 1)
    PDF::Reader.stubs(:new).returns(reader)

    error = assert_raises(Provider::Codex::Error) do
      Provider::Codex.new.send(:validate_page_count!, "%PDF")
    end

    assert_includes error.message, "up to #{Provider::Codex::MAX_PAGES} pages"
  end

  test "extracts device login details from colorized cli output" do
    Provider::Codex.expects(:write_login_state).with(
      "login-id",
      {
        state: "awaiting_auth",
        login_url: "https://auth.openai.com/codex/device",
        user_code: "WJQW-ANFT6"
      }
    )

    Provider::Codex.send(
      :record_login_output,
      "login-id",
      "  \e[94mhttps://auth.openai.com/codex/device\e[0m  \e[94mWJQW-ANFT6\e[0m\n"
    )
  end

  test "logs out through the Codex CLI" do
    status = mock
    status.stubs(:success?).returns(true)
    Open3.expects(:capture3).with(Provider::Codex.executable_path, "logout").returns([ "", "", status ])

    assert Provider::Codex.perform_logout
  end
end
