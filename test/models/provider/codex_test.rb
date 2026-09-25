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
      image_paths: [ "/tmp/page-1.png" ]
    )
  end

  test "omits optional model and reasoning arguments when unset" do
    provider = Provider::Codex.new(command: "/usr/bin/codex", model: nil, reasoning_effort: nil)

    args = provider.send(
      :command_args,
      schema_path: "/tmp/schema.json",
      output_path: "/tmp/output.json",
      image_paths: []
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
  end
end
