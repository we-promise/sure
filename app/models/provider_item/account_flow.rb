# frozen_string_literal: true

# The shared flow for choosing which of a connection's provider accounts to link:
# which connection is selected, the accounts it reports (cached per connection)
# and which of them are still free to link. Each provider subclasses it as
# `<Key>Item::AccountFlow` and implements the hooks below. The connection model
# needs `active`, `with_credentials` and `ordered` scopes and
# `credentials_configured?`; its provider accounts store the provider's id in
# `account_id`.
class ProviderItem::AccountFlow
  CACHE_TTL = 5.minutes

  class NoApiTokenError < StandardError; end

  SelectionResult = Data.define(:status, :item, :available_accounts, :accountable_type, :message) do
    def success? = status == :success
    def setup_required? = status == :setup_required
    def provider_error? = status.in?([ :api_error, :unexpected_error ])
  end

  attr_reader :family, :item_id, :item, :credentialed_items

  def self.item_class
    module_parent
  end

  def self.provider_key
    item_class.provider_key
  end

  # The item params whose change makes the cached accounts stale.
  def self.cache_sensitive_params
    raise NotImplementedError, "#{name} must define .cache_sensitive_params"
  end

  def self.cache_key(family, item)
    "#{provider_key}_accounts_#{family.id}_#{item.id}"
  end

  def self.cache_sensitive_update?(permitted_params)
    cache_sensitive_params.any? { |param| permitted_params.key?(param) }
  end

  def self.update_item_with_cache_expiration(item, family:, attributes:)
    expire_accounts_cache = cache_sensitive_update?(attributes)
    updated = item.update(attributes)

    Rails.cache.delete(cache_key(family, item)) if updated && expire_accounts_cache

    updated
  end

  def initialize(family:, item_id: nil, item: nil)
    @family = family
    @item_id = item_id.to_s.strip.presence
    @credentialed_items = family.public_send(self.class.item_class.connection_declaration[:association]).active.with_credentials.ordered
    @item = item || resolve_item(@item_id)
  end

  def selected?
    item.present?
  end

  def selection_required?
    credentialed_items.count > 1 && item_id.blank?
  end

  def preload_payload
    return selection_error_payload if !selected?
    return { success: false, error: "no_credentials", has_accounts: false } unless item.credentials_configured?

    cached_accounts = Rails.cache.read(cache_key)
    cached = !cached_accounts.nil?
    available_accounts = cached ? cached_accounts : fetch_and_cache_accounts

    { success: true, has_accounts: available_accounts.any?, cached: cached }
  rescue NoApiTokenError
    { success: false, error: "no_api_token", has_accounts: false }
  rescue provider_error_class => e
    Rails.logger.error("#{provider_name} preload error: #{e.message}")
    { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
  rescue StandardError => e
    Rails.logger.error("Unexpected error preloading #{provider_name} accounts: #{e.class}: #{e.message}")
    { success: false, error: "unexpected_error", error_message: I18n.t("#{i18n_scope}.errors.unexpected_error"), has_accounts: nil }
  end

  def select_accounts_result(accountable_type:)
    selection_result_for(
      scope: "#{i18n_scope}.select_accounts",
      accountable_type: accountable_type,
      empty_message_key: "no_accounts_found",
      log_context: "select_accounts"
    )
  end

  def select_existing_account_result(account:)
    return linked_account_result if account.account_providers.exists?

    selection_result_for(
      scope: "#{i18n_scope}.select_existing_account",
      accountable_type: account.accountable_type,
      empty_message_key: "all_accounts_already_linked",
      log_context: "select_existing_account"
    )
  end

  private

    # The provider's raw account payloads for the selected item.
    def fetch_accounts
      raise NotImplementedError, "#{self.class.name} must define #fetch_accounts"
    end

    # The family's credentialed item with this id, or its only one.
    def resolve_item(_item_id)
      raise NotImplementedError, "#{self.class.name} must define #resolve_item"
    end

    # The error the provider's client raises for API failures.
    def provider_error_class
      raise NotImplementedError, "#{self.class.name} must define #provider_error_class"
    end

    def provider_key
      self.class.provider_key
    end

    def i18n_scope
      "#{provider_key}_items"
    end

    def provider_name
      provider_key.titleize
    end

    def adapter_class
      "Provider::#{provider_key.camelize}Adapter".constantize
    end

    def selection_error_payload
      if item_id.present?
        return {
          success: false,
          error: "select_connection",
          error_message: I18n.t("#{i18n_scope}.select_accounts.select_connection"),
          has_accounts: nil
        }
      end

      return { success: false, error: "no_credentials", has_accounts: false } unless selection_required?

      {
        success: false,
        error: "select_connection",
        error_message: I18n.t("#{i18n_scope}.select_accounts.select_connection"),
        has_accounts: nil
      }
    end

    def selection_failure_result(scope, accountable_type: nil)
      if selection_required?
        self.class::SelectionResult.new(
          status: :select_connection,
          item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.select_connection")
        )
      else
        self.class::SelectionResult.new(
          status: :setup_required,
          item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.no_credentials_configured")
        )
      end
    end

    def selection_result_for(scope:, accountable_type:, empty_message_key:, log_context:)
      return selection_failure_result(scope, accountable_type: accountable_type) unless selected?

      available_accounts = filter_accounts(unlinked_available_accounts, accountable_type)
      if available_accounts.empty?
        return selection_result(
          status: :empty,
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.#{empty_message_key}")
        )
      end

      selection_result(status: :success, accountable_type: accountable_type, available_accounts: available_accounts)
    rescue NoApiTokenError
      selection_result(
        status: :no_api_token,
        accountable_type: accountable_type,
        message: I18n.t("#{scope}.no_api_token")
      )
    rescue provider_error_class => e
      Rails.logger.error("#{provider_name} API error in #{log_context}: #{e.message}")
      selection_result(status: :api_error, accountable_type: accountable_type, message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error in #{log_context}: #{e.class}: #{e.message}")
      selection_result(
        status: :unexpected_error,
        accountable_type: accountable_type,
        message: I18n.t("#{scope}.unexpected_error")
      )
    end

    def selection_result(status:, accountable_type:, available_accounts: [], message: nil)
      self.class::SelectionResult.new(
        status: status,
        item: item,
        available_accounts: available_accounts,
        accountable_type: accountable_type,
        message: message
      )
    end

    def linked_account_result
      self.class::SelectionResult.new(
        status: :account_already_linked,
        item: item,
        available_accounts: [],
        accountable_type: nil,
        message: I18n.t("#{i18n_scope}.select_existing_account.account_already_linked")
      )
    end

    def cache_key
      self.class.cache_key(family, item)
    end

    def accounts
      cached_accounts = Rails.cache.read(cache_key)
      return cached_accounts unless cached_accounts.nil?

      fetch_and_cache_accounts
    end

    def fetch_and_cache_accounts
      available_accounts = fetch_accounts
      Rails.cache.write(cache_key, available_accounts, expires_in: CACHE_TTL)
      available_accounts
    end

    def unlinked_available_accounts
      provider_accounts = item.provider_accounts
      linked_account_ids = provider_accounts.joins(:account_provider)
                                            .pluck("#{provider_accounts.klass.table_name}.account_id")
                                            .map(&:to_s)
      accounts.reject { |account| linked_account_ids.include?(account.with_indifferent_access[:id].to_s) }
    end

    # A provider narrows the accounts it offers for a type by overriding
    # account_offered_as?; by default every account is offered for every
    # supported type.
    def filter_accounts(accounts, accountable_type)
      return [] unless supported_account_type?(accountable_type)

      accounts.select { |account| account_offered_as?(account, accountable_type) }
    end

    def account_offered_as?(_account, _accountable_type)
      true
    end

    def supported_account_type?(accountable_type)
      adapter_class.supported_account_types.include?(accountable_type)
    end
end
