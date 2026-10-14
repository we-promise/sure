require "test_helper"

class HostingDocsOllamaBindingTest < ActiveSupport::TestCase
  FILES = %w[compose.example.ai.yml docs/hosting/ai.md docs/hosting/docker.md].freeze

  test "published Ollama port is bound to loopback only" do
    FILES.each do |path|
      Rails.root.join(path).read.each_line.with_index(1) do |line, number|
        next unless line.match?(/["']?\d*\.?\d*\.?\d*\.?\d*:?11434:11434["']?/) && line.strip.start_with?("-")

        assert_match(/127\.0\.0\.1:11434:11434/, line, "#{path}:#{number} publishes Ollama on all interfaces")
      end
    end
  end
end
