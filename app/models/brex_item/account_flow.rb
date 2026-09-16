# frozen_string_literal: true

class BrexItem::AccountFlow
  require_dependency "brex_item/account_flow/setup"

  include Setup

  CACHE_TTL = 5.minutes

  class NoApiTokenError < StandardError; end
  class AccountNotFoundError < StandardError; end
  class InvalidAccountNameError < StandardError; end
  class AccountAlreadyLinkedError < StandardError; end

  NavigationResult = Data.define(:target, :flash_type, :message)

  SelectionResult = Data.define(:status, :brex_item, :available_accounts, :accountable_type, :message) do
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

  attr_reader :family, :brex_item_id, :brex_item, :credentialed_items, :selection_token

  def initialize(family:, brex_item_id: nil, brex_item: nil, actor: Current.user, selection_token: nil)
    @family = family
    @actor, @submitted_selection_token = actor, selection_token
    @brex_item_id = brex_item_id.to_s.strip.presence
    @credentialed_items = family.brex_items.active.with_credentials.ordered
    @brex_item = brex_item || BrexItem.resolve_for(family: family, brex_item_id: @brex_item_id)
    if @brex_item && @brex_item.family_id != family.id
      raise Provider::AccountData::LegacyWriterFence::OwnershipChanged, "Brex source belongs to another family"
    end
  end

  def self.cache_key(family, brex_item)
    raise Provider::AccountData::LegacyWriterFence::OwnershipChanged unless brex_item.family_id == family.id
    BrexItem::Selection.cache_key(brex_item)
  end

  def self.cache_sensitive_update?(permitted_params)
    permitted_params.key?(:token) || permitted_params.key?(:base_url)
  end

  def self.update_item_with_cache_expiration(brex_item, family:, attributes:, actor: Current.user)
    raise Provider::AccountData::LegacyWriterFence::OwnershipChanged unless brex_item.family_id == family.id
    current = BrexItem::Lifecycle.new(item: brex_item, actor: actor).update_settings(attributes)
    brex_item.assign_attributes(current.attributes.except("id"))
    current.errors.each { |error| brex_item.errors.add(error.attribute, error.message) }
    current.errors.empty?
  end

  def selected?
    brex_item.present?
  end

  def selection_required?
    credentialed_items.count > 1 && brex_item_id.blank?
  end

  def preload_payload
    return selection_error_payload if !selected?
    return { success: false, error: "no_credentials", has_accounts: false } unless brex_item.credentials_configured?

    result = lifecycle.discover
    { success: true, has_accounts: result.fetch(:accounts).any?, cached: result.fetch(:cached) }
  rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue NoApiTokenError
    { success: false, error: "no_api_token", has_accounts: false }
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex preload error: #{e.message}")
    { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
  rescue StandardError => e
    Rails.logger.error("Unexpected error preloading Brex accounts: #{e.class}: #{e.message}")
    { success: false, error: "unexpected_error", error_message: I18n.t("brex_items.errors.unexpected_error"), has_accounts: nil }
  end

  def select_accounts_result(accountable_type:)
    selection_result_for(
      scope: "brex_items.select_accounts",
      accountable_type: accountable_type,
      empty_message_key: "no_accounts_found",
      log_context: "select_accounts"
    )
  end

  def select_existing_account_result(account:)
    selection_result_for(
      scope: "brex_items.select_existing_account",
      accountable_type: account.accountable_type,
      empty_message_key: "all_accounts_already_linked",
      log_context: "select_existing_account", account_id: account.id
    )
  end

  def link_new_accounts_result(account_ids:, accountable_type:)
    return navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.no_accounts_selected")) if account_ids.blank?
    return navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.invalid_account_type")) unless supported_account_type?(accountable_type)
    return navigation(:settings_providers, :alert, I18n.t("brex_items.link_accounts.select_connection")) unless selected?

    link_navigation_result(link_new_accounts!(account_ids: account_ids, accountable_type: accountable_type))
  rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue NoApiTokenError
    navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.no_api_token"))
  rescue Provider::Brex::BrexError => e
    navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.api_error", message: e.message))
  rescue StandardError => e
    Rails.logger.error("Brex account linking failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    navigation(:new_account, :alert, I18n.t("brex_items.errors.unexpected_error"))
  end

  def link_existing_account_result(account:, brex_account_id:)
    return navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.missing_parameters")) if account.blank? || brex_account_id.blank?
    return navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.account_already_linked")) if account.account_providers.exists?
    return navigation(:settings_providers, :alert, I18n.t("brex_items.link_existing_account.select_connection")) unless selected?

    link_existing_account!(account: account, brex_account_id: brex_account_id)

    navigation(:return_to_or_accounts, :notice, I18n.t("brex_items.link_existing_account.success", account_name: account.name))
  rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue NoApiTokenError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.no_api_token"))
  rescue AccountNotFoundError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.provider_account_not_found"))
  rescue InvalidAccountNameError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.invalid_account_name"))
  rescue AccountAlreadyLinkedError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.provider_account_already_linked"))
  rescue Provider::Brex::BrexError => e
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.api_error", message: e.message))
  rescue StandardError => e
    Rails.logger.error("Brex existing account linking failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    navigation(:accounts, :alert, I18n.t("brex_items.errors.unexpected_error"))
  end

  def link_new_accounts!(account_ids:, accountable_type:)
    raise ArgumentError, "Unsupported Brex account type: #{accountable_type}" unless supported_account_type?(accountable_type)
    result = lifecycle.link_accounts(account_ids: account_ids, account_type: accountable_type, selection: selection(:link_accounts))
    LinkAccountsResult.new(created_accounts: result.fetch(:created_accounts),
      already_linked_names: result.fetch(:already_linked_accounts), invalid_account_ids: result.fetch(:invalid_accounts))
  end

  def link_existing_account!(account:, brex_account_id:)
    result = lifecycle.link_existing_account(account_id: account.id, brex_account_id: brex_account_id,
      selection: selection(:link_existing_account, account_id: account.id))
    case result[:error]
    when :account_already_linked, :brex_account_already_linked then raise AccountAlreadyLinkedError
    when :brex_account_not_found then raise AccountNotFoundError
    when :invalid_account_name then raise InvalidAccountNameError
    end
    result.fetch(:account).account_providers.find_by!(provider_type: "BrexAccount").provider
  end
  private

    def selection_error_payload
      if brex_item_id.present?
        return {
          success: false,
          error: "select_connection",
          error_message: I18n.t("brex_items.select_accounts.select_connection"),
          has_accounts: nil
        }
      end

      return { success: false, error: "no_credentials", has_accounts: false } unless selection_required?

      {
        success: false,
        error: "select_connection",
        error_message: I18n.t("brex_items.select_accounts.select_connection"),
        has_accounts: nil
      }
    end

    def selection_failure_result(scope, accountable_type: nil)
      if selection_required?
        SelectionResult.new(
          status: :select_connection,
          brex_item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.select_connection")
        )
      else
        SelectionResult.new(
          status: :setup_required,
          brex_item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.no_credentials_configured")
        )
      end
    end

    def selection_result_for(scope:, accountable_type:, empty_message_key:, log_context:, account_id: nil)
      return selection_failure_result(scope, accountable_type: accountable_type) unless selected?
      result = lifecycle.discover(flow: account_id ? :link_existing_account : :link_accounts, account_id: account_id)
      return linked_account_result if result[:account_already_linked]
      @brex_item, @selection_token = result.values_at(:item, :selection_token)
      available_accounts = filter_accounts(result.fetch(:accounts), accountable_type)
      if available_accounts.empty?
        return selection_result(
          status: :empty,
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.#{empty_message_key}")
        )
      end

      selection_result(status: :success, accountable_type: accountable_type, available_accounts: available_accounts)
    rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue NoApiTokenError
      selection_result(
        status: :no_api_token,
        accountable_type: accountable_type,
        message: I18n.t("#{scope}.no_api_token")
      )
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex API error in #{log_context}: #{e.message}")
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
      SelectionResult.new(
        status: status,
        brex_item: brex_item,
        available_accounts: available_accounts,
        accountable_type: accountable_type,
        message: message
      )
    end

    def linked_account_result
      SelectionResult.new(
        status: :account_already_linked,
        brex_item: brex_item,
        available_accounts: [],
        accountable_type: nil,
        message: I18n.t("brex_items.select_existing_account.account_already_linked")
      )
    end

    def link_navigation_result(result)
      if result.invalid_count.positive? && result.created_count.zero? && result.already_linked_count.zero?
        navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.invalid_account_names", count: result.invalid_count))
      elsif result.invalid_count.positive? && (result.created_count.positive? || result.already_linked_count.positive?)
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "brex_items.link_accounts.partial_invalid",
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
            "brex_items.link_accounts.partial_success",
            created_count: result.created_count,
            already_linked_count: result.already_linked_count,
            already_linked_names: result.already_linked_names.join(", ")
          )
        )
      elsif result.created_count.positive?
        navigation(:return_to_or_accounts, :notice, I18n.t("brex_items.link_accounts.success", count: result.created_count))
      elsif result.already_linked_count.positive?
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "brex_items.link_accounts.all_already_linked",
            count: result.already_linked_count,
            names: result.already_linked_names.join(", ")
          )
        )
      else
        navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.link_failed"))
      end
    end

    def navigation(target, flash_type, message)
      NavigationResult.new(target: target, flash_type: flash_type, message: message)
    end

    def cache_key
      self.class.cache_key(family, brex_item)
    end

    def filter_accounts(accounts, accountable_type)
      return [] unless Provider::BrexAdapter.supported_account_types.include?(accountable_type)

      accounts.select do |account|
        case accountable_type
        when "CreditCard"
          BrexAccount.kind_for(account) == "card"
        when "Depository"
          BrexAccount.kind_for(account) == "cash"
        else
          true
        end
      end
    end

    def lifecycle
      BrexItem::Lifecycle.new(item: brex_item, actor: @actor)
    end

    def selection(flow, account_id: nil)
      BrexItem::Selection.from_token(@submitted_selection_token, flow: flow, account_id: account_id)
    end

    def supported_account_type?(accountable_type)
      Provider::BrexAdapter.supported_account_types.include?(accountable_type)
    end
end
