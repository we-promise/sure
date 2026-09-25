require "json"
require "open3"
require "stringio"
require "tmpdir"
require "timeout"

# Uses a locally authenticated Codex CLI installation for self-hosted users who
# have a ChatGPT/Codex subscription but no OpenAI API key. This is deliberately
# opt-in per import: the normal API-key provider remains the default.
class Provider::Codex < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)
  DEFAULT_TIMEOUT = 10.minutes
  LOGIN_TIMEOUT = 15.minutes
  LOGIN_STATE_TTL = 20.minutes
  MAX_TEXT_SIZE = 100_000
  MAX_PAGES = 5
  DEFAULT_PROMPT = <<~PROMPT.freeze
    Analyze the financial PDF text below. Return only the structured JSON required by the output schema.
    Do not invent values. If this is a bank or credit-card statement, extract every transaction you can see.
    Amounts must be signed consistently: inflows positive and outflows negative.
    Use ISO dates (YYYY-MM-DD) where possible. Use null when a field is not visible.
  PROMPT

  class << self
    def default_prompt
      DEFAULT_PROMPT
    end

    def configured?
      executable_path.present?
    end

    def authentication_status
      command = executable_path
      return { state: "unavailable" } if command.blank?

      _stdout, _stderr, status = Open3.capture3(command, "login", "status")
      { state: status.success? ? "connected" : "not_connected" }
    rescue StandardError => e
      Rails.logger.warn("Codex login status check failed: #{e.class}: #{e.message}")
      { state: "not_connected" }
    end

    def perform_logout
      command = executable_path
      return false if command.blank?

      _stdout, stderr, status = Open3.capture3(command, "logout")
      return true if status.success?

      Rails.logger.warn("Codex logout failed: #{stderr.to_s.truncate(500)}")
      false
    rescue StandardError => e
      Rails.logger.warn("Codex logout failed: #{e.class}: #{e.message}")
      false
    end

    def prepare_login(login_id)
      write_login_state(login_id, state: "queued")
    end

    def login_state(login_id)
      return if login_id.blank?

      Rails.cache.read(login_cache_key(login_id))
    end

    def perform_device_login(login_id)
      command = executable_path
      if command.blank?
        write_login_state(login_id, state: "unavailable")
        return
      end

      write_login_state(login_id, state: "starting")
      stdin = output = wait_thread = nil

      begin
        stdin, output, wait_thread = Open3.popen2e(command, "login", "--device-auth")
        stdin.close

        Timeout.timeout(LOGIN_TIMEOUT) do
          output.each_line { |line| record_login_output(login_id, line) }
        end

        authenticated = authentication_status[:state] == "connected"
        write_login_state(login_id, state: authenticated ? "connected" : "failed")
      rescue Timeout::Error
        terminate_login_process(wait_thread)
        write_login_state(login_id, state: "timed_out")
      rescue StandardError => e
        Rails.logger.warn("Codex login failed: #{e.class}: #{e.message}")
        write_login_state(login_id, state: "failed")
      ensure
        output&.close unless output&.closed?
        wait_thread&.join(1)
      end
    end

    def executable_path
      command = ENV["CODEX_COMMAND"].presence || "codex"
      return command if command.start_with?("/") && File.executable?(command)
      command = File.basename(command) if command.start_with?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        path = File.join(directory, command)
        path if File.executable?(path)
      end.first
    end

    private

      def write_login_state(login_id, attributes)
        existing = login_state(login_id) || {}
        Rails.cache.write(
          login_cache_key(login_id),
          existing.merge(attributes.stringify_keys),
          expires_in: LOGIN_STATE_TTL
        )
      end

      def login_cache_key(login_id)
        "codex-login:#{login_id}"
      end

      def record_login_output(login_id, line)
        text = line.to_s.gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "").strip
        return if text.blank?

        login_url = text[%r{https?://[^\s<>()]+}]&.delete_suffix(",")
        user_code = text[/\b[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+\b/]
        write_login_state(
          login_id,
          {
            state: "awaiting_auth",
            login_url: login_url,
            user_code: user_code
          }.compact
        )
      end

      def terminate_login_process(wait_thread)
        return unless wait_thread&.alive?

        Process.kill("TERM", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
  end

  def initialize(
    command: self.class.executable_path,
    model: ENV["CODEX_MODEL"].presence,
    reasoning_effort: ENV["CODEX_REASONING_EFFORT"].presence,
    timeout: nil
  )
    @command = command
    @model = model
    @reasoning_effort = reasoning_effort
    @timeout = timeout.presence&.to_i || ENV.fetch("CODEX_REQUEST_TIMEOUT", DEFAULT_TIMEOUT.to_i).to_i
  end

  def provider_name
    "Codex (subscription)"
  end

  def supported_models_description
    @model.presence || "the locally authenticated Codex account"
  end

  def supports_model?(_model)
    true
  end

  def supports_pdf_processing?
    @command.present?
  end

  def process_pdf(pdf_content:, family: nil)
    with_provider_response do
      raise Error, "Codex CLI is not installed or not executable" if @command.blank?

      run(pdf_content, family: family)
    end
  end

  private

    def run(pdf_content, family:)
      raise Error, "PDF content is empty" if pdf_content.blank?

      Dir.mktmpdir("sure-codex-pdf") do |tmpdir|
        schema_path = File.join(tmpdir, "output-schema.json")
        output_path = File.join(tmpdir, "last-message.json")
        File.write(schema_path, JSON.generate(output_schema))
        image_paths = render_pages(pdf_content, tmpdir)

        args = command_args(schema_path: schema_path, output_path: output_path, image_paths: image_paths)

        stdout, stderr, status = Timeout.timeout(@timeout) do
          Open3.capture3(@command, *args, stdin_data: prompt_for(pdf_content, image_paths, family: family), chdir: tmpdir)
        end

        unless status.success?
          Rails.logger.warn("Codex PDF processing failed: exit=#{status.exitstatus} stderr=#{stderr.to_s.truncate(500)}")
          raise Error, "Codex could not process the PDF"
        end

        parse_result(File.file?(output_path) ? File.read(output_path) : stdout)
      end
    rescue Timeout::Error
      raise Error, "Codex PDF processing timed out"
    rescue JSON::ParserError
      raise Error, "Codex returned invalid PDF analysis JSON"
    end

    def command_args(schema_path:, output_path:, image_paths:)
      args = [
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox", "read-only",
        "--output-schema", schema_path,
        "--output-last-message", output_path
      ]
      args.push("--model", @model) if @model.present?
      if @reasoning_effort.present?
        args.push("--config", "model_reasoning_effort=#{@reasoning_effort.dump}")
      end
      image_paths.first(MAX_PAGES).each { |path| args.push("--image", path) }
      args << "-"
    end

    def prompt_for(pdf_content, image_paths, family:)
      text = extract_text(pdf_content)
      raise Error, "Could not read the PDF" if text.blank? && image_paths.empty?
      instructions = family&.ai_prompt(:codex_pdf).presence || self.class.default_prompt

      <<~PROMPT
        #{instructions.to_s.strip}

        PDF text (page images are also attached when the PDF has a visual-only page):
        #{text.to_s.truncate(MAX_TEXT_SIZE)}
      PROMPT
    end

    def render_pages(pdf_content, tmpdir)
      pdf_path = File.join(tmpdir, "input.pdf")
      output_prefix = File.join(tmpdir, "page")
      File.binwrite(pdf_path, pdf_content)
      _stdout, _stderr, status = Open3.capture3("pdftoppm", "-f", "1", "-l", MAX_PAGES.to_s, "-png", "-r", "150", pdf_path, output_prefix)
      return [] unless status.success?

      Dir.glob(File.join(tmpdir, "page-*.png")).sort
    rescue Errno::ENOENT
      []
    end

    def extract_text(pdf_content)
      reader = PDF::Reader.new(StringIO.new(pdf_content))
      reader.pages.first(MAX_PAGES).each_with_index.map do |page, index|
        "--- Page #{index + 1} ---\n#{page.text}"
      end.join("\n\n")
    rescue StandardError => e
      Rails.logger.warn("Codex PDF text extraction failed: #{e.class}: #{e.message}")
      nil
    end

    def parse_result(raw)
      parsed = JSON.parse(raw.to_s.gsub(/\A```(?:json)?\s*|\s*```\z/, "").strip)
      raise JSON::ParserError unless parsed.is_a?(Hash)

      data = parsed["extracted_data"]
      data = {} unless data.is_a?(Hash)

      Provider::LlmConcept::PdfProcessingResult.new(
        summary: parsed["summary"].to_s.presence,
        document_type: parsed["document_type"].to_s.presence || "other",
        extracted_data: data
      )
    end

    def output_schema
      transaction = {
        type: "object",
        additionalProperties: false,
        properties: {
          date: { type: [ "string", "null" ] },
          amount: { type: [ "number", "string", "null" ] },
          name: { type: [ "string", "null" ] },
          category: { type: [ "string", "null" ] },
          notes: { type: [ "string", "null" ] }
        },
        required: %w[date amount name category notes]
      }

      {
        type: "object",
        additionalProperties: false,
        properties: {
          document_type: { type: "string", enum: Import::DOCUMENT_TYPES },
          summary: { type: [ "string", "null" ] },
          extracted_data: {
            type: "object",
            additionalProperties: false,
            properties: { transactions: { type: "array", items: transaction } },
            required: [ "transactions" ]
          }
        },
        required: %w[document_type summary extracted_data]
      }
    end
end
