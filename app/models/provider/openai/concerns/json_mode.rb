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

  private
    # The OpenAI endpoint's JSON mode in Ai::Config, which Ai::LegacyEnvConfig resolves from
    # LLM_JSON_MODE, then Setting.openai_json_mode, then auto. Only the PDF workers still read
    # it here.
    def default_json_mode
      endpoint = Ai::Config.current.endpoints.find { _1.protocol == :compatible && _1.name.start_with?("openai") }
      # A caller with its own client and no OpenAI endpoint configured still gets the operator's mode.
      mode = endpoint ? endpoint.json_mode.to_s : Ai::LegacyEnvConfig.openai_json_mode
      VALID_JSON_MODES.include?(mode) ? mode : JSON_MODE_AUTO
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
end
