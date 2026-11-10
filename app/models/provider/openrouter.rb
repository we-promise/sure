class Provider::Openrouter < Provider::Openai
  ENDPOINT = "https://openrouter.ai/api/v1".freeze
  MODEL_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\/[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/

  def self.valid_model_id?(model)
    model.is_a?(String) && model.length <= 255 && MODEL_ID_PATTERN.match?(model)
  end

  def self.family_client_options
    super.merge(uri_base: ENDPOINT)
  end

  def initialize(access_token, model:)
    raise Error, "An OpenRouter model ID is required" unless self.class.valid_model_id?(model)

    super(access_token, model: model, use_global_settings: false)
  end

  def provider_name
    "OpenRouter"
  end

  def custom_provider?
    true
  end

  def supports_model?(model)
    model == default_model
  end

  # Catalog tool support does not imply structured-output support. Keep the
  # prompts and JSON parsing, but do not request an unverified response format.
  def auto_categorize(json_mode: nil, **options)
    super(**options, json_mode: json_mode || "none")
  end

  def auto_detect_merchants(json_mode: nil, **options)
    super(**options, json_mode: json_mode || "none")
  end

  def enhance_provider_merchants(json_mode: nil, **options)
    super(**options, json_mode: json_mode || "none")
  end

  def extract_bank_statement(json_mode: nil, **options)
    super(**options, json_mode: json_mode || "none")
  end

  # The selected text model can analyze locally extracted PDF text. Model names
  # do not establish image or native PDF support on an API-compatible endpoint.
  def supports_pdf_processing?(model: default_model)
    supports_model?(model)
  end

  def process_pdf(pdf_content:, model: "", family: nil, json_mode: nil)
    with_provider_response do
      effective_model = model.presence || default_model
      raise Error, "Model is not configured for OpenRouter" unless supports_model?(effective_model)

      Provider::Openai::PdfProcessor.new(
        client,
        model: effective_model,
        pdf_content: pdf_content,
        custom_provider: true,
        family: family,
        max_response_tokens: max_response_tokens,
        processing_mode: :text,
        json_mode: json_mode || "none"
      ).process
    end
  end
end
