# frozen_string_literal: true

# A read-only snapshot of optional installation configuration. Resolving a
# provider constructs its client; it never tests credentials or fetches data.
class ConfigurationHealth
  STORAGE_BACKENDS = {
    "local" => "Disk", "test" => "Disk", "amazon" => "S3",
    "cloudflare" => "S3", "generic_s3" => "S3", "google" => "GCS"
  }.freeze

  Check = Data.define(:key, :status, :issues, :providers, :backend) do
    def tone
      status.in?([ :not_configured, :incomplete ]) ? :warning : :neutral
    end
  end

  ProviderStatus = Data.define(:key, :status)

  def checks
    @checks ||= [ smtp, securities, exchange_rates, storage ]
  end

  def optional_services
    @optional_services ||= OptionalServices.new.checks
  end

  def smtp
    return check(:smtp, :disabled) unless ApplicationMailer.perform_deliveries
    return check(:smtp, :not_checked) unless ApplicationMailer.delivery_method == :smtp

    settings = ApplicationMailer.smtp_settings.symbolize_keys
    issues = []
    issues << :address if settings[:address].blank?
    port = Integer(settings[:port], exception: false)
    issues << :port unless port && (1..65_535).cover?(port)
    issues << :sender unless email_sender_configured?
    issues << :app_domain if ApplicationMailer.default_url_options[:host].blank?
    # Unauthenticated relays are supported; a half-configured credential pair
    # is different from intentionally supplying neither field.
    issues << :authentication if settings[:user_name].present? != settings[:password].present?

    status = if issues.include?(:address)
      :not_configured
    elsif issues.any?
      :incomplete
    else
      :configured
    end
    check(:smtp, status, issues: issues)
  end

  def securities
    providers = provider_statuses(:securities, Setting.enabled_securities_providers)
    check(:securities, provider_status(providers, empty_status: :disabled), providers: providers)
  end

  def exchange_rates
    selected = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    providers = provider_statuses(:exchange_rates, [ selected ].compact_blank)
    check(:exchange_rates, provider_status(providers), providers: providers)
  end

  def storage
    # Read configuration without constructing a storage client: SDK credential
    # discovery can contact metadata servers, even without a bucket operation.
    name = Rails.application.config.active_storage.service.to_s
    configurations = Rails.application.config.active_storage.service_configurations ||
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    settings = configurations.with_indifferent_access[name]
    backend = STORAGE_BACKENDS.key?(name) ? name.to_sym : :other
    return check(:storage, :not_configured, backend: backend) if settings.blank?
    settings = settings.symbolize_keys
    unless STORAGE_BACKENDS[name] == settings[:service]
      return check(:storage, :not_checked, backend: :other)
    end
    issues = storage_issues(name, settings)
    status = if issues.any?
      :incomplete
    elsif name.in?(%w[amazon cloudflare generic_s3]) && settings[:access_key_id].blank?
      :not_checked # An SDK credential chain / instance role may supply access.
    elsif name == "google" && settings[:credentials].blank?
      :not_checked # Application Default Credentials may supply access.
    else
      :configured
    end
    check(:storage, status, issues: issues, backend: backend)
  end

  private
    def check(key, status, issues: [], providers: [], backend: nil)
      Check.new(key: key, status: status, issues: issues, providers: providers, backend: backend)
    end

    def email_sender_configured?
      sender = Mail::Address.new(ApplicationMailer.default[:from].to_s)
      sender.local.present? && sender.domain.present? && sender.address != "sender@sure.local"
    rescue Mail::Field::ParseError
      false
    end

    def storage_issues(name, settings)
      return settings[:root].present? ? [] : [ :root ] if name.in?(%w[local test])

      issues = []
      issues << :bucket if settings[:bucket].blank?
      if name.in?(%w[amazon cloudflare generic_s3])
        issues << :region if settings[:region].blank?
        if settings[:access_key_id].present? != settings[:secret_access_key].present?
          issues << :credentials
        end
      end
      if name.in?(%w[cloudflare generic_s3])
        if settings[:endpoint].blank? || settings[:endpoint] == "https://.r2.cloudflarestorage.com"
          issues << :endpoint
        end
      end
      issues
    end

    def provider_statuses(concept, names)
      registry = Provider::Registry.for_concept(concept)
      names.uniq.map do |name|
        # Never display an arbitrary ENV/setting value (it may contain an
        # accidentally pasted credential), or resolve outside this concept.
        key = registry.provider_keys.find { |candidate| candidate.to_s == name }
        next ProviderStatus.new(key: :unknown, status: :invalid) unless key

        status = registry.get_provider(key).present? ? :configured : :not_configured
        ProviderStatus.new(key: key, status: status)
      end
    end

    def provider_status(providers, empty_status: :not_configured)
      return empty_status if providers.empty?
      return :configured if providers.all? { |provider| provider.status == :configured }
      return :incomplete if providers.any? { |provider| provider.status.in?([ :configured, :invalid ]) }

      :not_configured
    end
end
