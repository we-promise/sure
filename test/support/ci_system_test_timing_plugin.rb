require "json"
require "fileutils"
require "minitest"
require "pathname"
require "time"

module CiSystemTestTimingPlugin
  OUTPUT_DIR = File.expand_path("../../tmp/ci", __dir__)

  THEME_ALIASES = {
    "account" => "accounts",
    "drag" => "imports",
    "import" => "imports",
    "transaction" => "transactions",
    "setting" => "settings"
  }.freeze

  class Reporter < Minitest::StatisticsReporter
    attr_reader :entries

    def start
      super
      @entries = []
    end

    def record(result)
      super

      source_location = Array(result.source_location)
      file = source_location.first
      line = source_location.last
      relative_file = file && Pathname.new(file).relative_path_from(Pathname.pwd).to_s

      @entries << {
        class_name: result.class_name,
        name: result.name,
        location: line && relative_file ? "#{relative_file}:#{line}" : relative_file,
        file: relative_file,
        theme: theme_for(relative_file),
        time: result.time.to_f,
        assertions: result.assertions,
        failures: result.failures.size,
        skipped: result.skipped?,
        error: result.error?
      }
    end

    def report
      write_reports
      super
    end

    private
      def write_reports
        return if entries.empty?

        FileUtils.mkdir_p(OUTPUT_DIR)

        payload = {
          generated_at: Time.now.utc.iso8601,
          total_time: total_time,
          test_count: entries.size,
          groups: grouped_summary,
          slowest: slowest_entries,
          tests: entries.sort_by { |entry| -entry[:time] }
        }

        json_path = File.join(OUTPUT_DIR, "system_test_timing.json")
        markdown_path = File.join(OUTPUT_DIR, "system_test_timing.md")

        File.write(json_path, JSON.pretty_generate(payload))

        markdown = build_markdown(payload)
        File.write(markdown_path, markdown)

        puts
        puts markdown

        append_step_summary(markdown)
      end

      def grouped_summary
        entries
          .group_by { |entry| entry[:theme] }
          .map do |theme, theme_entries|
            {
              theme: theme,
              total_time: theme_entries.sum { |entry| entry[:time] },
              test_count: theme_entries.size,
              slowest_test: theme_entries.max_by { |entry| entry[:time] }
            }
          end
          .sort_by { |group| -group[:total_time] }
      end

      def slowest_entries(limit = 15)
        entries.sort_by { |entry| -entry[:time] }.first(limit)
      end

      def build_markdown(payload)
        lines = []
        lines << "## System test timing summary"
        lines <<
          "Measured #{payload[:test_count]} tests in #{format_seconds(payload[:total_time])}. " \
          "Grouped by likely split theme for future workflow sharding."
        lines << ""
        lines << "### Slowest themes"
        lines << "| Theme | Total | Tests | Slowest test |"
        lines << "| --- | ---: | ---: | --- |"

        payload[:groups].each do |group|
          slowest_test = group[:slowest_test]
          lines << "| #{group[:theme]} | #{format_seconds(group[:total_time])} | #{group[:test_count]} | #{slowest_test[:class_name]}##{slowest_test[:name]} (#{format_seconds(slowest_test[:time])}) |"
        end

        lines << ""
        lines << "### Slowest individual tests"
        lines << "| Test | Theme | Time | Location |"
        lines << "| --- | --- | ---: | --- |"

        payload[:slowest].each do |entry|
          lines << "| #{entry[:class_name]}##{entry[:name]} | #{entry[:theme]} | #{format_seconds(entry[:time])} | `#{entry[:location]}` |"
        end

        lines << ""
        lines << "Artifacts: `tmp/ci/system_test_timing.json`, `tmp/ci/system_test_timing.md`"
        lines.join("\n")
      end

      def append_step_summary(markdown)
        summary_path = ENV["GITHUB_STEP_SUMMARY"]
        return if summary_path.to_s.empty?

        File.open(summary_path, "a") do |file|
          file.puts(markdown)
          file.puts
        end
      end

      def format_seconds(seconds)
        format("%.2fs", seconds)
      end

      def theme_for(relative_file)
        return "unknown" if relative_file.to_s.empty?

        test_path = relative_file.sub(%r{\Atest/system/}, "")
        first_segment = test_path.split("/").first.to_s.sub(/_test\.rb\z/, "")
        stem = first_segment.split("_").first

        stem = nil if stem.nil? || stem.empty?
        THEME_ALIASES.fetch(stem, stem || "unknown")
      end
  end

  def self.minitest_plugin_init(_options)
    Minitest.reporter << Reporter.new($stdout, {})
  end
end

Minitest.register_plugin(CiSystemTestTimingPlugin)
