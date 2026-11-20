# frozen_string_literal: true

# The shared flow for linking a connection's provider accounts: which connection
# is selected, the accounts it reports (cached per connection), which of them
# are still free, linking them to new or existing accounts, and setting up the
# imported ones (Setup). Each provider
# subclasses it as `<Key>Item::AccountFlow` and implements the hooks below. The
# connection model needs `active`, `with_credentials` and `ordered` scopes and
# `credentials_configured?`; its provider account class stores the provider's
# id in `account_id` and answers `name_for`, `currency_for` and
# `default_accountable_attributes` for a payload. Setup creates accounts from a
# provider account's `name`, `current_balance` and `currency` columns and reads
# its `account_provider` association.
class ProviderItem::AccountFlow
  require_dependency "provider_item/account_flow/setup"

  include Setup

  CACHE_TTL = 5.minutes

  class NoApiTokenError < StandardError; end

  class AccountNotFoundError < StandardError; end
  class InvalidAccountNameError < StandardError; end
  class AccountAlreadyLinkedError < StandardError; end

  NavigationResult = Data.define(:target, :flash_type, :message)

  SelectionResult = Data.define(:status, :item, :available_accounts, :accountable_type, :message) do
    def success? = status == :success
    def setup_required? = status == :setup_required
    def provider_error? = status.in?([ :api_error, :unexpected_error ])
  end

  LinkAccountsResult = Data.define(:created_accounts, :already_linked_names, :invalid_account_ids) do
    def created_count = created_accounts.count
    def already_linked_count = already_linked_names.count
    def invalid_count = invalid_account_ids.count
  end

  SetupResult = Data.define(:created_accounts, :skipped_count, :failed_count) do
    def created_count = created_accounts.count
  end

  SetupCompletion = Data.define(:success, :message) do
    def success? = success
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

  def self.adapter_class
    "Provider::#{provider_key.camelize}Adapter".constantize
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
    return unsupported_account_type_result(account.accountable_type) unless supported_account_type?(account.accountable_type)

    selection_result_for(
      scope: "#{i18n_scope}.select_existing_account",
      accountable_type: account.accountable_type,
      empty_message_key: "all_accounts_already_linked",
      log_context: "select_existing_account"
    )
  end

  def link_new_accounts_result(account_ids:, accountable_type:)
    return navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.no_accounts_selected")) if account_ids.blank?
    return navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.invalid_account_type")) unless supported_account_type?(accountable_type)
    return navigation(:settings_providers, :alert, I18n.t("#{i18n_scope}.link_accounts.select_connection")) unless selected?

    link_navigation_result(link_new_accounts!(account_ids: account_ids, accountable_type: accountable_type))
  rescue NoApiTokenError
    navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.no_api_token"))
  rescue provider_error_class => e
    navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.api_error", message: e.message))
  rescue StandardError => e
    Rails.logger.error("#{provider_name} account linking failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    navigation(:new_account, :alert, I18n.t("#{i18n_scope}.errors.unexpected_error"))
  end

  def link_existing_account_result(account:, provider_account_id:)
    return navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.missing_parameters")) if account.blank? || provider_account_id.blank?
    return navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.account_already_linked")) if account.account_providers.exists?
    return navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_accounts.invalid_account_type")) unless supported_account_type?(account.accountable_type)
    return navigation(:settings_providers, :alert, I18n.t("#{i18n_scope}.link_existing_account.select_connection")) unless selected?

    link_existing_account!(account: account, provider_account_id: provider_account_id)

    navigation(:return_to_or_accounts, :notice, I18n.t("#{i18n_scope}.link_existing_account.success", account_name: account.name))
  rescue NoApiTokenError
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.no_api_token"))
  rescue AccountNotFoundError
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.provider_account_not_found"))
  rescue InvalidAccountNameError
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.invalid_account_name"))
  rescue AccountAlreadyLinkedError
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.provider_account_already_linked"))
  rescue provider_error_class => e
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.link_existing_account.api_error", message: e.message))
  rescue StandardError => e
    Rails.logger.error("#{provider_name} existing account linking failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    navigation(:accounts, :alert, I18n.t("#{i18n_scope}.errors.unexpected_error"))
  end

  def link_new_accounts!(account_ids:, accountable_type:)
    raise ArgumentError, "Unsupported #{provider_name} account type: #{accountable_type}" unless supported_account_type?(accountable_type)

    created_accounts = []
    already_linked_names = []
    invalid_account_ids = []
    accounts_by_id = indexed_accounts

    ActiveRecord::Base.transaction do
      account_ids.each do |account_id|
        account_data = accounts_by_id[account_id.to_s]
        next unless account_data

        account_name = provider_account_class.name_for(account_data)

        if account_name.blank?
          invalid_account_ids << account_id
          Rails.logger.warn "#{self.class.name} - Skipping account #{account_id} with blank name"
          next
        end

        provider_account = upsert_provider_account!(account_id, account_data)

        if provider_account.account_provider.present?
          already_linked_names << account_name
          next
        end

        account = Account.create_and_sync(
          {
            family: family,
            name: account_name,
            balance: 0,
            currency: provider_account.currency.presence || provider_account_class.currency_for(account_data),
            accountable_type: accountable_type,
            accountable_attributes: provider_account_class.default_accountable_attributes(accountable_type)
          },
          skip_initial_sync: true
        )

        AccountProvider.create!(account: account, provider: provider_account)
        created_accounts << account
      end
    end

    item.sync_later if created_accounts.any?

    LinkAccountsResult.new(
      created_accounts: created_accounts,
      already_linked_names: already_linked_names,
      invalid_account_ids: invalid_account_ids
    )
  end

  def link_existing_account!(account:, provider_account_id:)
    account_data = indexed_accounts[provider_account_id.to_s]
    raise AccountNotFoundError unless account_data

    account_name = provider_account_class.name_for(account_data)
    raise InvalidAccountNameError if account_name.blank?

    provider_account = nil

    ActiveRecord::Base.transaction do
      provider_account = upsert_provider_account!(provider_account_id, account_data)
      raise AccountAlreadyLinkedError if provider_account.account_provider.present?

      AccountProvider.create!(account: account, provider: provider_account)
    end

    item.sync_later

    provider_account
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

    # Creates or refreshes the item's provider account for this payload.
    def upsert_provider_account!(_account_id, _account_data)
      raise NotImplementedError, "#{self.class.name} must define #upsert_provider_account!"
    end

    # Whether the payload differs from what the provider account last stored.
    def provider_account_snapshot_changed?(_provider_account, _account_data)
      raise NotImplementedError, "#{self.class.name} must define #provider_account_snapshot_changed?"
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
      self.class.adapter_class
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

    def unsupported_account_type_result(accountable_type)
      selection_result(
        status: :empty,
        accountable_type: accountable_type,
        message: I18n.t("#{i18n_scope}.link_accounts.invalid_account_type")
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

    # The list is cached only if the connection's credentials are unchanged
    # since the fetch began: an update that drops the cache mid-fetch must not
    # have the old credentials' accounts written back under the same key.
    def fetch_and_cache_accounts
      credentials = cache_credentials(item)
      available_accounts = fetch_accounts
      if cache_credentials(item.class.find_by(id: item.id)) == credentials
        Rails.cache.write(cache_key, available_accounts, expires_in: CACHE_TTL)
      end
      available_accounts
    end

    def cache_credentials(record)
      record && self.class.cache_sensitive_params.map { |param| record.public_send(param) }
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

    def link_navigation_result(result)
      if result.invalid_count.positive? && result.created_count.zero? && result.already_linked_count.zero?
        navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.invalid_account_names", count: result.invalid_count))
      elsif result.invalid_count.positive? && (result.created_count.positive? || result.already_linked_count.positive?)
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "#{i18n_scope}.link_accounts.partial_invalid",
            created_count: result.created_count,
            already_linked_count: result.already_linked_count,
            invalid_count: result.invalid_count
          )
        )
      elsif result.created_count.positive? && result.already_linked_count.positive?
        navigation(
          :return_to_or_accounts,
          :notice,
          I18n.t(
            "#{i18n_scope}.link_accounts.partial_success",
            created_count: result.created_count,
            already_linked_count: result.already_linked_count,
            already_linked_names: result.already_linked_names.join(", ")
          )
        )
      elsif result.created_count.positive?
        navigation(:return_to_or_accounts, :notice, I18n.t("#{i18n_scope}.link_accounts.success", count: result.created_count))
      elsif result.already_linked_count.positive?
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "#{i18n_scope}.link_accounts.all_already_linked",
            count: result.already_linked_count,
            names: result.already_linked_names.join(", ")
          )
        )
      else
        navigation(:new_account, :alert, I18n.t("#{i18n_scope}.link_accounts.link_failed"))
      end
    end

    def navigation(target, flash_type, message)
      NavigationResult.new(target: target, flash_type: flash_type, message: message)
    end

    def indexed_accounts
      accounts.index_by { |account| account.with_indifferent_access[:id].to_s }
    end

    def provider_account_class
      item.provider_accounts.klass
    end

    def supported_account_type?(accountable_type)
      adapter_class.supported_account_types.include?(accountable_type)
    end
end
