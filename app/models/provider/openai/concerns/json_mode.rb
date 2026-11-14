# Resolves the JSON response-format mode and applies it to a chat params hash.
#
# Every provider call that asks the model for structured output has to decide
# how hard to constrain decoding. `response_format` is the OpenAI parameter for
# that, but it is also the most widely rejected parameter across
# OpenAI-compatible runtimes -- LM Studio, for example, answers
# "'response_format.type' must be 'json_schema' or 'text'" and never reaches the
# model. Self-hosters need a way to turn the constraint off without patching the
# app, which is what JSON_MODE_NONE is for.
#
# This concern was extracted from the identical copies that previously lived in
# AutoCategorizer, AutoMerchantDetector, and ProviderMerchantEnhancer. Those
# classes resolved the mode but not all of them applied it, and the document
# extraction path (BankStatementExtractor, PdfProcessor) applied neither -- it
# hardcoded `json_object`.
module Provider::Openai::Concerns::JsonMode
  extend ActiveSupport::Concern

  # JSON response format modes for custom providers
  # - "strict": Use strict JSON schema (requires full OpenAI API compatibility)
  # - "json_object": Use json_object response format (broader compatibility)
  # - "none": No response format constraint (maximum compatibility with local LLMs)
  # - "auto": Let the caller's fallback strategy decide
  JSON_MODE_STRICT = "strict"
  JSON_MODE_OBJECT = "json_object"
  JSON_MODE_NONE = "none"
  JSON_MODE_AUTO = "auto"

  VALID_JSON_MODES = [ JSON_MODE_STRICT, JSON_MODE_OBJECT, JSON_MODE_NONE, JSON_MODE_AUTO ].freeze

  # Threshold for auto mode: if more than this percentage returns null, retry with none mode
  AUTO_MODE_NULL_THRESHOLD = 0.5

  private
    # Determine default JSON mode based on configuration hierarchy:
    # 1. Environment variable (LLM_JSON_MODE) - highest priority, for testing/override
    # 2. Setting.openai_json_mode - user-configured in app settings
    # 3. Default: auto mode (recommended for all providers)
    #
    # Mode descriptions:
    # - "auto": Tries strict first, falls back to none if >50% fail (recommended default)
    # - "strict": Best for thinking models (qwen-thinking, deepseek-reasoner) - skips verbose <think> tags
    # - "none": Best for non-thinking models (gpt-oss, llama, mistral) - allows reasoning in output
    # - "json_object": Middle ground, broader compatibility than strict
    def default_json_mode
      # 1. Check environment variable first (allows runtime override for testing)
      env_mode = ENV["LLM_JSON_MODE"]
      return env_mode if env_mode.present? && VALID_JSON_MODES.include?(env_mode)

      # 2. Check app settings (user-configured)
      setting_mode = Setting.openai_json_mode
      return setting_mode if setting_mode.present? && VALID_JSON_MODES.include?(setting_mode)

      # 3. Default: auto mode for all providers (tries strict first, falls back to none if needed)
      JSON_MODE_AUTO
    end

    # Applies the resolved mode to a `client.chat` params hash, in place.
    #
    # `strict` only becomes a JSON schema request when the caller supplies one;
    # calls that have no schema to offer degrade to `json_object`, which is what
    # they sent before modes existed. Callers that pair `auto` with a fallback
    # strategy do the same, since there is nothing to fall back from here.
    def apply_json_mode(params, mode:, schema: nil)
      case mode
      when JSON_MODE_NONE
        params
      when JSON_MODE_STRICT
        if schema.present?
          params[:response_format] = { type: "json_schema", json_schema: schema }
        else
          params[:response_format] = { type: "json_object" }
        end
      else
        params[:response_format] = { type: "json_object" }
      end
    end

    # Runs a structured-output chat request under `mode` with the shared
    # fallback strategy. The block receives (mode, with_reasoning_effort) and
    # performs one request. Strict requests rejected with HTTP 400 are retried
    # once in none mode without the response format or the reasoning effort,
    # since either can cause the 400; auto mode handles its own strict attempt
    # below, so a 400 reaching this rescue in auto mode came from the none-mode
    # retry and propagates.
    def request_with_json_mode_fallback(mode, operation:, expected_count:, failed:, &request)
      if mode == JSON_MODE_AUTO
        request_with_auto_mode(operation: operation, expected_count: expected_count, failed: failed, &request)
      else
        request.call(mode, true)
      end
    rescue Faraday::BadRequestError => e
      raise unless mode == JSON_MODE_STRICT

      Rails.logger.warn("Strict JSON mode failed for #{operation}, falling back to none mode: #{e.message}")
      request.call(JSON_MODE_NONE, false)
    end

    # Auto mode: try strict first, fall back to none when the provider rejects
    # the schema, the reply cannot be parsed, or too many results are null or
    # missing. Models that cannot reason in strict mode often return null for
    # everything or omit the items they cannot handle, so if more than
    # AUTO_MODE_NULL_THRESHOLD of the expected results failed the request is
    # retried without the constraint. Only the provider-rejection retry drops
    # the reasoning effort.
    def request_with_auto_mode(operation:, expected_count:, failed:, &request)
      result = begin
        request.call(JSON_MODE_STRICT, true)
      rescue Provider::Openai::ResponseFormatError => e
        Rails.logger.warn("Auto mode: strict JSON response for #{operation} could not be parsed (#{e.message}), retrying with none mode")
        return request.call(JSON_MODE_NONE, true)
      rescue Faraday::BadRequestError => e
        Rails.logger.warn("Auto mode: strict JSON mode rejected by provider for #{operation} (#{e.message}), retrying with none mode")
        return request.call(JSON_MODE_NONE, false)
      end

      null_count = result.count(&failed)
      missing_count = expected_count - result.size
      failed_ratio = expected_count > 0 ? (null_count + missing_count).to_f / expected_count : 0.0
      return result unless failed_ratio > AUTO_MODE_NULL_THRESHOLD

      Rails.logger.info("Auto mode: #{(failed_ratio * 100).round}% of #{operation} failed (#{null_count} nulls, #{missing_count} missing) in strict mode, retrying with none mode")
      request.call(JSON_MODE_NONE, true)
    end
end
