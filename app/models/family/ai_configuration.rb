class Family::AiConfiguration < ApplicationRecord
  self.table_name = "family_ai_configurations"
  self.filter_attributes += [ :encrypted_api_key ]

  InvalidCredential = Class.new(StandardError)
  PROVIDERS = %w[openai anthropic openrouter].freeze
  PRIVATE_ATTRIBUTES = %w[api_key encrypted_api_key].freeze

  belongs_to :family

  validates :provider, inclusion: { in: PROVIDERS }
  validates :model, presence: true, length: { maximum: 255 }, format: { without: /[\r\n]/ }
  validates :encrypted_api_key, presence: true
  validate :valid_openrouter_model

  before_validation :assign_default_model

  def self.default_model(provider)
    case provider.to_s
    when "openai" then Provider::Openai::DEFAULT_MODEL
    when "anthropic" then Provider::Anthropic::DEFAULT_MODEL
    end
  end

  def api_key=(value)
    raise InvalidCredential, "Family is required before assigning credentials" if family_id.blank?

    self.encrypted_api_key = value.present? ? encryptor.encrypt_and_sign(value.to_s, purpose: credential_purpose) : nil
  end

  def api_key
    return if encrypted_api_key.blank?

    encryptor.decrypt_and_verify(encrypted_api_key, purpose: credential_purpose).tap do |value|
      raise InvalidCredential, "Family credential is invalid" unless value.is_a?(String) && value.present?
    end
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
    raise InvalidCredential, "Family credential is invalid"
  end

  # An existing record is an explicit override. Missing or unreadable credentials
  # must never send this family's data through the installation's credentials.
  def provider_instance(name = provider)
    return unless PROVIDERS.include?(provider) && name.to_s == provider
    return if provider == "openrouter" && !Provider::Openrouter.valid_model_id?(model)

    token = api_key
    return if token.blank?

    options = { model: model.presence || self.class.default_model(provider), use_global_settings: false }
    case provider
    when "openai" then Provider::Openai.new(token, **options)
    when "anthropic" then Provider::Anthropic.new(token, **options)
    when "openrouter" then Provider::Openrouter.new(token, model: model)
    end
  rescue InvalidCredential
    Rails.logger.warn("Family AI credential could not be read for family #{family_id}")
    nil
  end

  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + PRIVATE_ATTRIBUTES
    options[:methods] = Array(options[:methods]).reject { |name| PRIVATE_ATTRIBUTES.include?(name.to_s) } if options[:methods]
    super(options).except(*PRIVATE_ATTRIBUTES)
  end

  private
    def valid_openrouter_model
      if provider == "openrouter" && !Provider::Openrouter.valid_model_id?(model)
        errors.add(:model, :invalid)
      end
    end

    def assign_default_model
      self.model = self.class.default_model(provider) if model.blank?
    end

    def credential_purpose
      "family-ai-configuration:#{family_id}"
    end

    def encryptor
      @encryptor ||= begin
        key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key("family_ai_configuration", 32)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
end
