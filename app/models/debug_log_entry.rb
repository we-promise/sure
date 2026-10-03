# frozen_string_literal: true

class DebugLogEntry < ApplicationRecord
  include Encryptable

  LEVELS = %w[debug info warn error].freeze

  # Key names redacted anywhere in metadata (any nesting depth), regardless of which
  # call site wrote them — a safety net for the many capture(...) sites across provider
  # importers that this class has no direct visibility into, on top of the individual
  # sites that were audited and fixed not to pass these in the first place.
  SENSITIVE_METADATA_KEY_PATTERN = /amount|balance|address|\bbody\b|qty|\buid\b|api_account_id|api_key|access_token|refresh_token|password|authorization|secret|iban|account_number|email/i

  # Credential shapes redacted inside string values (e.g. an error_message that
  # embeds an Authorization header or a serialized JSON fragment) — key-based
  # redaction alone cannot catch secrets hiding in innocuously named keys.
  # The sensitive-key alternative consumes quoted strings, unquoted scalars
  # (42.5, null, true) and complete compound values — `compound` recurses via
  # \g<compound> so nested objects/arrays like {"body":{"note":"..."}} are
  # swallowed whole rather than leaking everything past the opening brace.
  SENSITIVE_METADATA_VALUE_PATTERNS = [
    /\b(?:Bearer|Basic)\s+[A-Za-z0-9\-._~+\/=]+/i,
    /"[^"]*(?:#{SENSITIVE_METADATA_KEY_PATTERN.source})[^"]*"\s*(?::|=>)\s*(?:"[^"]*"|(?<compound>[\{\[](?:[^{}\[\]"]|"(?:\\.|[^"\\])*"|\g<compound>)*[\}\]])|[^,}\]\s"]+)/i
  ].freeze

  if encryption_ready?
    encrypts :metadata
  end

  belongs_to :family, optional: true
  belongs_to :account, optional: true
  belongs_to :user, optional: true
  belongs_to :account_provider, optional: true

  validates :category, :level, :message, :source, presence: true
  validates :level, inclusion: { in: LEVELS }

  scope :recent, -> { order(created_at: :desc) }
  scope :with_category, ->(category) { category.present? ? where(category: category) : all }
  scope :with_level, ->(level) { level.present? ? where(level: level) : all }
  scope :with_source, ->(source) { source.present? ? where(source: source) : all }
  scope :with_provider_key, ->(provider_key) { provider_key.present? ? where(provider_key: provider_key) : all }

  class << self
    def log!(category:, level:, message:, source:, metadata: {}, family: nil, family_id: nil,
             account: nil, account_id: nil, user: nil, user_id: nil,
             account_provider: nil, account_provider_id: nil, provider_key: nil, provider: nil)
      create!(
        category:,
        level:,
        message:,
        source:,
        metadata: normalize_metadata(metadata),
        family: resolve_family(family, family_id, account, account_id, user, user_id, account_provider, account_provider_id),
        account: resolve_account(account, account_id, account_provider, account_provider_id),
        user: resolve_user(user, user_id),
        account_provider: resolve_account_provider(account_provider, account_provider_id),
        provider_key: normalize_provider_key(provider_key, provider)
      )
    end

    def capture(...)
      log!(...)
    rescue => e
      Rails.logger.error("DebugLogEntry.capture failed: #{e.class}: #{e.message}")
      nil
    end

    # Public because the security:backfill_encryption task must run the same
    # redaction over pre-existing plaintext rows before re-encrypting them.
    def normalize_metadata(metadata)
      return {} if metadata.blank?
      return { value: metadata.to_s } unless metadata.respond_to?(:deep_stringify_keys)

      redact_sensitive(metadata.deep_stringify_keys)
    end

    private
      def redact_sensitive(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, v), result|
            result[key] = key.to_s.match?(SENSITIVE_METADATA_KEY_PATTERN) ? "[REDACTED]" : redact_sensitive(v)
          end
        when Array
          value.map { |v| redact_sensitive(v) }
        when String
          SENSITIVE_METADATA_VALUE_PATTERNS.reduce(value) { |result, pattern| result.gsub(pattern, "[REDACTED]") }
        else
          value
        end
      end

      def normalize_provider_key(provider_key, provider)
        return provider_key.to_s if provider_key.present?
        return if provider.blank?

        provider_name = provider.is_a?(String) || provider.is_a?(Symbol) ? provider.to_s : provider.class.name.demodulize
        provider_name.to_s.underscore
      end

      def resolve_family(family, family_id, account, account_id, user, user_id, account_provider, account_provider_id)
        family ||
          find_record(Family, family_id) ||
          resolve_account(account, account_id, account_provider, account_provider_id)&.family ||
          resolve_user(user, user_id)&.family
      end

      def resolve_account(account, account_id, account_provider, account_provider_id)
        account ||
          find_record(Account, account_id) ||
          resolve_account_provider(account_provider, account_provider_id)&.account
      end

      def resolve_user(user, user_id)
        user || find_record(User, user_id)
      end

      def resolve_account_provider(account_provider, account_provider_id)
        account_provider || find_record(AccountProvider, account_provider_id)
      end

      def find_record(klass, id)
        return if id.blank?

        klass.find_by(id: id)
      end
  end
end
