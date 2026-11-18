# frozen_string_literal: true

module RuboCop
  module Cop
    module Sure
      # Flags long heredocs in the AI layer and controllers:
      # a prompt is a file in app/prompts/<name>/ (instructions.txt.erb, input.txt.erb), rendered
      # by Ai::Prompt, so it's reviewed like code, can be overridden per route entry and per
      # locale, and is checked by test/architecture/ai_prompts_test.rb.
      #
      #   # bad
      #   def instructions
      #     <<~PROMPT
      #       You are an assistant to a consumer personal finance app...
      #       (a dozen more lines)
      #     PROMPT
      #   end
      #
      #   # good
      #   prompt "categorize_transactions"   # app/prompts/categorize_transactions/
      class NoPromptHeredoc < Base
        MSG = "Prompts live in app/prompts/<name>/ (instructions.txt.erb and input.txt.erb), not in heredocs. " \
              "See docs/llm-guides/ai-pipeline.md."
        MAX_LINES = 10

        def on_str(node) = check(node)
        def on_dstr(node) = check(node)
        def on_xstr(node) = check(node)

        private
          def check(node)
            return unless node.heredoc?

            lines = node.loc.heredoc_end.line - node.loc.heredoc_body.line
            add_offense(node) if lines > MAX_LINES
          end
      end
    end
  end
end
