# How a compatible endpoint is asked for JSON.
#
# - The Responses API always takes the strict schema.
# - Chat completions follow the route's JSON mode. `auto` walks strict, json_object, none: it
#   moves on when the answer doesn't parse or, for batched features, when more than half the
#   items came back blank or missing, keeping the reasoning effort. An explicit mode stays,
#   apart from the 400 retry below.
# - In `auto`, a 400 about the JSON mode moves to the next mode in the chain, so a server that
#   refuses a strict schema still gets `json_object` before `none`, as main's bill setup and PDF
#   extraction asked for it (LM Studio refuses both and reaches `none`).
# - A 400 to a request that sent an effort is retried once in `none` mode without the effort, as
#   main's 400 retries do since #3605: it can't tell the format from the effort. So is a 400 about
#   the JSON mode in an explicit mode. Gemini refuses an effort it doesn't take with "Request
#   contains an invalid argument", which names neither (seen live). A 400 about anything else (an
#   attachment, a missing model) ends the call, after that one retry if an effort was sent: the
#   next mode would resend the same request. OpenRouter's "reasoning is mandatory" isn't a
#   JSON-mode rejection.
# - No schema example is appended in `none` mode: the prompts for custom servers already show
#   the shape.
module Ai::Transport::JsonMode
  CHAINS = {
    auto: %i[strict json_object none], strict: %i[strict], json_object: %i[json_object], none: %i[none]
  }.freeze
  REJECTION = /response_format|json_schema|json_object|json mode|structured output|\bschema\b|reasoning_effort|reasoning\.effort|\beffort\b|unsupported (?:value|parameter)/i
  NOT_A_REJECTION = /mandatory/i

  # Turning reasoning off where a server ignores `reasoning_effort: none`, keyed by preset. The
  # endpoints the deprecated ENV builds have none of these presets.
  EFFORT_NONE = { llama_cpp: { chat_template_kwargs: { enable_thinking: false } } }.freeze

  private
    def generate_with_json_mode(request)
      return generate_with_responses(request) if endpoint.responses_api

      modes = CHAINS.fetch(request.json_mode)
      effort = request.reasoning_effort
      usage = nil
      retried = false
      index = 0

      while index < modes.size
        mode = modes[index]
        last = index == modes.size - 1
        begin
          text, tokens, finish_reason = attempt { complete_in_mode(request, mode, effort) }
        rescue Ai::Error::Refused => error
          raise unless rejection?(error, effort) && !retried && (mode != :none || effort)

          if effort.nil? && request.json_mode == :auto && !last
            index += 1
            next
          end

          retried = true
          effort = nil
          modes = %i[none]
          index = 0
          next
        end

        usage = usage ? usage + tokens : tokens
        begin
          json = parsed!(text, finish_reason, mode)
        rescue Ai::Error::InvalidOutput
          raise if last

          index += 1
          next
        end

        if request.json_mode == :auto && !last && blank_ratio(request, json) > Ai::Transport::Base::BLANK_RATIO_LIMIT
          index += 1
          next
        end

        return Ai::Transport::Base::Response.new(json:, usage:, finish_reason:, json_mode: mode)
      end
    end

    # Strict, always. A 400 about the effort is retried once without it.
    def generate_with_responses(request)
      effort = request.reasoning_effort
      begin
        text, usage, finish_reason = attempt { complete_in_mode(request, :strict, effort) }
      rescue Ai::Error::Refused => error
        raise unless effort && rejection?(error, effort)

        effort = nil
        retry
      end
      Ai::Transport::Base::Response.new(json: parsed!(text, finish_reason, :strict), usage:, finish_reason:, json_mode: :strict)
    end

    def complete_in_mode(request, mode, effort)
      options = effort == "none" ? EFFORT_NONE.fetch(endpoint.preset, {}) : {}
      effort = nil if options.any?
      case mode
      when :strict then complete_json(request, effort:, provider_options: options)
      when :json_object then complete_json(request, schema: false, response_format: { type: "json_object" }, effort:, provider_options: options)
      when :none then complete_json(request, schema: false, effort:, provider_options: options)
      end
    end

    def rejection?(error, effort)
      error.status == 400 && !error.message.match?(NOT_A_REJECTION) && (effort.present? || error.message.match?(REJECTION))
    end

    def blank_ratio(request, json) = request.failed_ratio ? request.failed_ratio.call(json).to_f : 0.0
end
