# frozen_string_literal: true

module RuboCop
  module Cop
    module Sure
      # Flags ENV reads of AI configuration. ENV variables are permanent once released and differ
      # between containers, so AI code reads its configuration through Ai::Config instead. Only the
      # loaders read the old variables.
      #
      #   # bad
      #   ENV["OPENAI_MODEL"]
      #   ENV.fetch("EMBEDDING_DIMENSIONS", 1024)
      #
      #   # good
      #   Ai.plan(:categorize, family:).model.name
      #
      # LANGFUSE_*, AI_DEBUG_MODE (an operator's logging switch) and the proxy variables aren't AI
      # configuration and aren't flagged.
      class NoAiEnv < Base
        MSG = "AI configuration lives in the `ai_*` tables and the AI config file, not in ENV. " \
              "Add a column, a preset field or a config file key instead. See docs/llm-guides/ai-pipeline.md."
        AI_NAME = /\A(OPENAI|ANTHROPIC|LLM|JEV|EMBEDDING|AI|CATEGORIZATION|ASSISTANT|EXTERNAL_ASSISTANT|VECTOR_STORE)_/
        EXEMPT = %w[AI_DEBUG_MODE].freeze

        # ENV["X"], ENV.fetch("X", ...), ENV.key?("X")
        def_node_matcher :env_read, <<~PATTERN
          {
            (send (const {nil? cbase} :ENV) :[] (str $_))
            (send (const {nil? cbase} :ENV) {:fetch :key? :has_key? :include?} (str $_) ...)
          }
        PATTERN

        def on_send(node)
          env_read(node) do |name|
            add_offense(node) if name.match?(AI_NAME) && !EXEMPT.include?(name)
          end
        end
      end
    end
  end
end
