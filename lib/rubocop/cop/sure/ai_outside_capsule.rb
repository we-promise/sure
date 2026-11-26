# frozen_string_literal: true

module RuboCop
  module Cop
    module Sure
      # Flags deliberate opt-outs from the AI capsule. Every model call runs in a job on an AI
      # queue; evals are the only code that calls a model from the command line. The opt-out is
      # narrow and allowlisted, so a web thread can't quietly use it to bypass the check.
      #
      #   # bad
      #   Ai::Capsule.outside { transport.generate(request) }
      #
      #   # good (in app/models/eval/** or lib/tasks/evals.rake)
      #   Ai::Capsule.outside { Ai::Config.with(config) { generation.call } }
      #
      #   # good (in a job on an AI queue)
      #   generation.call
      class AiOutsideCapsule < Base
        MSG = "Only evals may call Ai::Capsule.outside; run AI calls in a job on an AI queue. " \
              "See docs/llm-guides/ai-pipeline.md."

        def_node_matcher :outside_call, <<~PATTERN
          (send (const (const {nil? cbase} :Ai) :Capsule) :outside ...)
        PATTERN

        def on_send(node)
          add_offense(node) if outside_call(node)
        end
      end
    end
  end
end
