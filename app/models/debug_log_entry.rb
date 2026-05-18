# frozen_string_literal: true

class DebugLogEntry < ApplicationRecord
  LEVELS = %w[debug info warn error].freeze

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

    private
      def normalize_metadata(metadata)
        return {} if metadata.blank?
        return metadata.deep_stringify_keys if metadata.respond_to?(:deep_stringify_keys)

        { value: metadata.to_s }
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
