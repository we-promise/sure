class Assistant::HistoryTrimmer
  def initialize(messages, max_tokens:)
    @messages = messages || []
    @max_tokens = max_tokens.to_i
  end

  def call
    return [] if @messages.empty? || @max_tokens <= 0

    groups = group_tool_pairs(@messages)
    current = open_turn_start(groups)
    kept = groups[current..].flatten(1)
    tokens = Assistant::TokenEstimator.estimate(kept)

    groups[0...current].reverse_each do |group|
      group_tokens = Assistant::TokenEstimator.estimate(group)
      break if tokens + group_tokens > @max_tokens

      kept.unshift(*group)
      tokens += group_tokens
    end

    kept
  end

  private

    # The question being answered and everything after it always survive:
    # dropping them would discard the very message the model is asked to
    # answer. So do the tools that replies failing since the last finished
    # one already ran, with the question that led to them: a model that does
    # not see them runs them again. A failed reply is replayed without its
    # text (Message#replayed_content), so an assistant entry with text is a
    # reply that finished.
    def open_turn_start(groups)
      last_answer = groups.rindex { |group| finished_reply?(group.first) } || -1
      unanswered_tools = ((last_answer + 1)...groups.size).find { |index| assistant_with_tool_calls?(groups[index].first) }
      anchor = unanswered_tools || groups.size - 1

      groups[0..anchor].rindex { |group| group.first[:role].to_s == "user" } || anchor
    end

    def finished_reply?(msg)
      msg[:role].to_s == "assistant" && msg[:content].present?
    end

    # Bundles each assistant message that has `tool_calls` with the
    # consecutive `role: "tool"` results that follow it, so the trimmer
    # never splits a call/result pair when dropping from the oldest end.
    def group_tool_pairs(messages)
      groups = []
      current_group = nil

      messages.each do |msg|
        if assistant_with_tool_calls?(msg)
          groups << current_group if current_group
          current_group = [ msg ]
        elsif msg[:role].to_s == "tool" && current_group
          current_group << msg
        else
          groups << current_group if current_group
          current_group = nil
          groups << [ msg ]
        end
      end

      groups << current_group if current_group
      groups
    end

    def assistant_with_tool_calls?(msg)
      msg[:role].to_s == "assistant" && msg[:tool_calls].is_a?(Array) && msg[:tool_calls].any?
    end
end
