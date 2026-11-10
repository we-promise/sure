require "open3"

# Sends Anthropic Messages requests through the Claude Code CLI (`claude -p`),
# so a self-hosted install can run its AI features on the owner's Claude
# subscription: CLAUDE_CODE_OAUTH_TOKEN, minted with `claude setup-token`.
# It stands in for the slice of ::Anthropic::Client that Provider::Anthropic
# uses (`messages.create` and `messages.stream`), so every helper keeps its
# prompts, schemas and parsing unchanged.
#
# The CLI runs locked down: no built-in tools, no settings, skills, slash
# commands or MCP servers, no saved session, and an environment rebuilt from
# nothing, so only the token reaches the child process. Tool calls are
# answered through `--json-schema` structured output instead of native tool
# use: a single structured-output tool returns its input directly, and chat's
# function list is folded into one schema of text plus calls.
class Provider::Anthropic::ClaudeCodeClient
  Error = Class.new(StandardError)

  Message = Struct.new(:id, :model, :role, :content, :stop_reason, :usage, keyword_init: true)
  Usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens, keyword_init: true)
  TextBlock = Struct.new(:type, :text, keyword_init: true)
  ToolUseBlock = Struct.new(:type, :id, :name, :input, keyword_init: true)

  # The CLI returns the whole answer at once, so the stream is one text event.
  Stream = Struct.new(:accumulated_message) do
    def each
      text = accumulated_message.content.select { |block| block.type == :text }.map(&:text).join("\n")
      yield ::Anthropic::Streaming::TextEvent.new(type: :text, text: text, snapshot: text) if text.present?
    end
  end

  def self.configured?
    ENV["CLAUDE_CODE_OAUTH_TOKEN"].present?
  end

  def initialize(token: ENV["CLAUDE_CODE_OAUTH_TOKEN"], timeout: 600, executable: ENV["CLAUDE_CODE_EXECUTABLE"].presence || "claude")
    @token = token
    @timeout = timeout
    @executable = executable
  end

  def messages
    self
  end

  def create(model:, messages:, system_: nil, tools: nil, tool_choice: nil, **)
    tools = tool_choice.is_a?(Hash) && tool_choice[:type].to_s == "none" ? [] : Array(tools)
    structured = structured_output_tool(tools, tool_choice)

    schema =
      if structured then structured[:input_schema]
      elsif tools.any? then function_call_schema(tools)
      end

    result = run(
      prompt: transcript(messages),
      system: [ system_text(system_), (tool_catalog(tools) if tools.any? && !structured) ].compact.join("\n\n").presence,
      model: model,
      schema: schema
    )

    build_message(result, model: model, structured: structured, function_calls: tools.any? && !structured)
  end

  def stream(**params)
    Stream.new(create(**params))
  end

  private
    attr_reader :token, :timeout, :executable

    # The structured-output helpers send exactly one tool with
    # disable_parallel_tool_use; chat sends its function list without it.
    def structured_output_tool(tools, tool_choice)
      return unless tools.one? && tool_choice.is_a?(Hash) && tool_choice[:disable_parallel_tool_use]

      tools.first
    end

    def function_call_schema(tools)
      {
        type: "object",
        properties: {
          text: { type: "string", description: "Reply to the user. Empty when only calling functions." },
          function_calls: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string", enum: tools.map { |tool| tool[:name] } },
                input: { type: "object", description: "Arguments matching the function's input schema." }
              },
              required: %w[name input]
            }
          }
        },
        required: %w[text function_calls],
        additionalProperties: false
      }
    end

    def tool_catalog(tools)
      catalog = tools.map { |tool| { name: tool[:name], description: tool[:description], input_schema: tool[:input_schema] } }

      <<~CATALOG
        You can call these functions. To call any, list them in function_calls and leave text empty;
        their results arrive in the next message. Answer in text once you have what you need.

        #{catalog.to_json}
      CATALOG
    end

    def system_text(system)
      return system if system.is_a?(String) || system.nil?

      Array(system).filter_map { |block| block_field(block, :text) }.join("\n\n")
    end

    # A lone user message goes as-is; a longer conversation is rendered as a
    # tagged transcript, since `-p` takes a single prompt.
    def transcript(messages)
      if messages.one? && messages.first[:role].to_s == "user" && messages.first[:content].is_a?(String)
        return messages.first[:content]
      end

      messages.map { |message| "<#{message[:role]}>\n#{render_content(message[:content])}\n</#{message[:role]}>" }.join("\n\n")
    end

    def render_content(content)
      return content.to_s unless content.is_a?(Array)

      content.map do |block|
        case block_field(block, :type).to_s
        when "text" then block_field(block, :text)
        when "tool_use" then "[called #{block_field(block, :name)} with #{block_field(block, :input).to_json}]"
        when "tool_result" then "[result of call #{block_field(block, :tool_use_id)}]\n#{render_content(block_field(block, :content))}"
        else raise Error, "Claude Code subscription mode does not support #{block_field(block, :type)} content"
        end
      end.join("\n")
    end

    def block_field(block, key)
      block.respond_to?(key) ? block.public_send(key) : (block[key] || block[key.to_s])
    end

    def command(model:, system:, schema:)
      [
        executable, "-p",
        "--output-format", "json",
        "--model", model.to_s,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence"
      ].tap do |cmd|
        cmd.push("--system-prompt", system) if system
        cmd.push("--json-schema", schema.to_json) if schema
      end
    end

    def child_env
      {
        "PATH" => ENV["PATH"],
        "HOME" => ENV["HOME"].presence || Dir.tmpdir,
        "CLAUDE_CODE_OAUTH_TOKEN" => token,
        "DISABLE_AUTOUPDATER" => "1",
        "HTTPS_PROXY" => ENV["HTTPS_PROXY"],
        "NO_PROXY" => ENV["NO_PROXY"]
      }.compact
    end

    def run(prompt:, system:, model:, schema:)
      raise Error, "CLAUDE_CODE_OAUTH_TOKEN is not set" if token.blank?

      out, err, status = capture(command(model: model, system: system, schema: schema), prompt)
      result = parse_result(out)

      unless status.success? && result && result["is_error"] != true && result["subtype"] == "success"
        detail = result&.dig("result").presence || err.to_s.strip.presence || "exit #{status.exitstatus}"
        raise Error, "Claude Code request failed: #{detail.to_s.truncate(500)}"
      end

      result
    end

    def capture(cmd, stdin_data)
      Open3.popen3(child_env, *cmd, unsetenv_others: true, chdir: Dir.tmpdir) do |stdin, stdout, stderr, wait|
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        # Written off the main thread so a CLI that stops reading can't hold
        # the request past its timeout; one that exits early (EPIPE) still
        # reports its own error through stdout.
        Thread.new do
          stdin.write(stdin_data)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          stdin.close unless stdin.closed?
        end

        unless wait.join(timeout)
          begin
            Process.kill("KILL", wait.pid)
          rescue Errno::ESRCH
            nil
          end
          wait.join
          raise Error, "Claude Code timed out after #{timeout}s"
        end

        [ out.value, err.value, wait.value ]
      end
    rescue Errno::ENOENT
      raise Error, "Claude Code CLI (#{executable}) is not installed in this image"
    end

    def parse_result(out)
      JSON.parse(out.to_s.lines.reverse.find { |line| line.lstrip.start_with?("{") } || "")
    rescue JSON::ParserError
      nil
    end

    def build_message(result, model:, structured:, function_calls:)
      output = result["structured_output"]

      content =
        if structured
          [ ToolUseBlock.new(type: :tool_use, id: "toolu_#{SecureRandom.hex(8)}", name: structured[:name], input: output || {}) ]
        elsif function_calls
          calls = Array(output&.dig("function_calls")).map do |call|
            ToolUseBlock.new(type: :tool_use, id: "toolu_#{SecureRandom.hex(8)}", name: call["name"], input: call["input"] || {})
          end
          [ (TextBlock.new(type: :text, text: output["text"]) if output&.dig("text").present?), *calls ].compact
        else
          [ TextBlock.new(type: :text, text: result["result"].to_s) ]
        end

      Message.new(
        id: result["session_id"] || "msg_#{SecureRandom.hex(8)}",
        model: model,
        role: :assistant,
        content: content,
        stop_reason: content.any? { |block| block.type == :tool_use } ? "tool_use" : "end_turn",
        usage: build_usage(result["usage"] || {})
      )
    end

    def build_usage(usage)
      Usage.new(
        input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i,
        cache_creation_input_tokens: usage["cache_creation_input_tokens"].to_i,
        cache_read_input_tokens: usage["cache_read_input_tokens"].to_i
      )
    end
end
