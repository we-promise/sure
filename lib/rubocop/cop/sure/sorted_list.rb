# frozen_string_literal: true

module RuboCop
  module Cop
    module Sure
      # Keeps a hash's keys, or an array's elements, in alphabetical order when the line
      # above the literal is the comment `# sorted`. Lists that every new provider extends
      # use it, so a new entry has a known place and two branches adding one rarely
      # conflict.
      #
      #   # sorted
      #   PENDING_PROVIDERS = %w[akahu plaid simplefin].freeze
      #
      #   # sorted
      #   enum :source, {
      #     akahu: "akahu",
      #     plaid: "plaid"
      #   }
      class SortedList < Base
        MSG = "Keep this `# sorted` list in alphabetical order: `%<item>s` belongs before `%<previous>s`."
        MARKER = /\A#\s*sorted\s*\z/

        def on_hash(node)
          check(node, node.pairs.map(&:key))
        end

        def on_array(node)
          check(node, node.values)
        end

        private

          def check(node, items)
            return unless marked?(node)

            names = items.map { |item| entry_name(item) }
            names.each_cons(2).with_index(1) do |(previous, current), index|
              next if previous <= current

              add_offense(items[index], message: format(MSG, item: current, previous: previous))
            end
          end

          def entry_name(item)
            item.sym_type? || item.str_type? ? item.value.to_s : item.source
          end

          # The marker is the comment on the line above the list. Only the outermost list
          # starting on the line after it is meant, not one nested in it.
          def marked?(node)
            return false if node.each_ancestor(:hash, :array).any? { |outer| outer.first_line == node.first_line }

            processed_source.comments.any? { |comment| comment.loc.line == node.first_line - 1 && comment.text.match?(MARKER) }
          end
      end
    end
  end
end
