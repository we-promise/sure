require "test_helper"

class Provider::Anthropic::ClaudeCodeClientTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Anthropic::ClaudeCodeClient.new(token: "sk-ant-oat-test")
  end

  test "answers a structured-output helper through --json-schema" do
    expect_cli(structured_output: { "categorizations" => [ { "transaction_id" => "txn_1", "category_name" => "Fast Food" } ] }) do |cmd, _prompt|
      schema = JSON.parse(cmd[cmd.index("--json-schema") + 1])
      assert_equal [ "categorizations" ], schema["required"]
      assert_equal "", cmd[cmd.index("--tools") + 1]
      assert_includes cmd, "--strict-mcp-config"
    end

    result = Provider::Anthropic::AutoCategorizer.new(
      @client,
      model: "claude-haiku-5-5",
      transactions: [ { id: "txn_1", name: "McDonalds", amount: 20 } ],
      user_categories: [ { id: "c1", name: "Fast Food" } ]
    ).auto_categorize

    assert_equal "txn_1", result.first.transaction_id
    assert_equal "Fast Food", result.first.category_name
  end

  test "folds chat functions into text plus function calls" do
    expect_cli(structured_output: { "text" => "", "function_calls" => [ { "name" => "get_accounts", "input" => { "limit" => 5 } } ] }) do |cmd, _prompt|
      assert_includes cmd[cmd.index("--system-prompt") + 1], "get_accounts"
    end

    message = @client.messages.create(
      model: "claude-haiku-5-5",
      system_: [ { type: "text", text: "You are a finance assistant." } ],
      messages: [ { role: "user", content: "How many accounts?" } ],
      tools: [ { name: "get_accounts", description: "List accounts", input_schema: { type: "object" } } ]
    )

    parsed = Provider::Anthropic::ChatParser.new(message).parsed
    assert_equal "get_accounts", parsed.function_requests.first.function_name
    assert_equal({ "limit" => 5 }, JSON.parse(parsed.function_requests.first.function_args))
    assert_equal 12, message.usage.input_tokens
  end

  test "renders tool results into the transcript" do
    expect_cli(result: "You have 2 accounts.", structured_output: { "text" => "You have 2 accounts.", "function_calls" => [] }) do |_cmd, prompt|
      assert_includes prompt, "<assistant>"
      assert_includes prompt, "[result of call toolu_1]"
    end

    message = @client.messages.create(
      model: "claude-haiku-5-5",
      messages: [
        { role: "user", content: "How many accounts?" },
        { role: "assistant", content: [ { type: "tool_use", id: "toolu_1", name: "get_accounts", input: {} } ] },
        { role: "user", content: [ { type: "tool_result", tool_use_id: "toolu_1", content: "[1, 2]" } ] }
      ],
      tools: [ { name: "get_accounts", description: "List accounts", input_schema: { type: "object" } } ]
    )

    assert_equal "You have 2 accounts.", message.content.first.text
    assert_equal "end_turn", message.stop_reason
  end

  test "raises when the CLI reports an error" do
    Provider::Anthropic::ClaudeCodeClient.any_instance.stubs(:capture).returns(
      [ { type: "result", subtype: "success", is_error: true, result: "Invalid API key" }.to_json, "", stub(success?: true) ]
    )

    error = assert_raises(Provider::Anthropic::ClaudeCodeClient::Error) do
      @client.messages.create(model: "claude-haiku-5-5", messages: [ { role: "user", content: "hi" } ])
    end
    assert_match "Invalid API key", error.message
  end

  test "the registry uses the subscription token only without an API key" do
    Setting.stubs(:anthropic_access_token).returns(nil)

    with_env_overrides("CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat-test", "ANTHROPIC_API_KEY" => nil, "ANTHROPIC_ACCESS_TOKEN" => nil) do
      provider = Provider::Registry.get_provider(:anthropic)
      assert_equal "Anthropic (Claude Code subscription)", provider.provider_name
    end

    with_env_overrides("CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat-test", "ANTHROPIC_API_KEY" => "sk-ant-api-test", "ANTHROPIC_ACCESS_TOKEN" => nil) do
      assert_equal "Anthropic", Provider::Registry.get_provider(:anthropic).provider_name
    end
  end

  test "times out a CLI that never reads its prompt" do
    client = Provider::Anthropic::ClaudeCodeClient.new(token: "t", timeout: 0.5, executable: fake_cli("exec sleep 30"))

    error = assert_raises(Provider::Anthropic::ClaudeCodeClient::Error) do
      client.messages.create(model: "claude-haiku-5-5", messages: [ { role: "user", content: "x" * 1_000_000 } ])
    end
    assert_match "timed out", error.message
  end

  test "reports the CLI's own error when it exits without reading the prompt" do
    script = %(echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}'; exit 1)
    client = Provider::Anthropic::ClaudeCodeClient.new(token: "t", executable: fake_cli(script))

    error = assert_raises(Provider::Anthropic::ClaudeCodeClient::Error) do
      client.messages.create(model: "claude-haiku-5-5", messages: [ { role: "user", content: "x" * 1_000_000 } ])
    end
    assert_match "Not logged in", error.message
  end

  private
    def fake_cli(body)
      file = Tempfile.new([ "claude", ".sh" ])
      file.write("#!/bin/sh
#{body}
")
      file.close
      File.chmod(0o755, file.path)
      (@fake_clis ||= []) << file
      file.path
    end

    def expect_cli(structured_output: nil, result: "", &check)
      payload = {
        type: "result", subtype: "success", is_error: false, session_id: "sess_1",
        result: result, structured_output: structured_output,
        usage: { input_tokens: 12, output_tokens: 34 }
      }

      Provider::Anthropic::ClaudeCodeClient.any_instance.expects(:capture).with do |cmd, prompt|
        check&.call(cmd, prompt)
        true
      end.returns([ payload.to_json, "", stub(success?: true) ])
    end
end
