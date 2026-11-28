# frozen_string_literal: true

class BrexItem::AccountFlow < ProviderItem::AccountFlow
  require_dependency "brex_item/account_flow/setup"

  include Setup

  # Setup is a nested module, so its constant lookup does not see constants
  # this class inherits.
  NoApiTokenError = ProviderItem::AccountFlow::NoApiTokenError

  class AccountNotFoundError < StandardError; end
  class InvalidAccountNameError < StandardError; end
  class AccountAlreadyLinkedError < StandardError; end

  NavigationResult = Data.define(:target, :flash_type, :message)

  SelectionResult = Class.new(superclass::SelectionResult) do
    def brex_item = item
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

  def self.cache_sensitive_params
    %i[token base_url]
  end

  def initialize(family:, brex_item_id: nil, brex_item: nil, item_id: nil, item: nil)
    super(family: family, item_id: brex_item_id || item_id, item: brex_item || item)
  end

  alias_method :brex_item, :item
  alias_method :brex_item_id, :item_id

  def link_new_accounts_result(account_ids:, accountable_type:)
    return navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.no_accounts_selected")) if account_ids.blank?
    return navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.invalid_account_type")) unless supported_account_type?(accountable_type)
    return navigation(:settings_providers, :alert, I18n.t("brex_items.link_accounts.select_connection")) unless selected?

    link_navigation_result(link_new_accounts!(account_ids: account_ids, accountable_type: accountable_type))
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

    created_accounts = []
    already_linked_names = []
    invalid_account_ids = []
    accounts_by_id = indexed_accounts

    ActiveRecord::Base.transaction do
      account_ids.each do |account_id|
        account_data = accounts_by_id[account_id.to_s]
        next unless account_data

        account_name = BrexAccount.name_for(account_data)

        if account_name.blank?
          invalid_account_ids << account_id
          Rails.logger.warn "BrexItem::AccountFlow - Skipping account #{account_id} with blank name"
          next
        end

        brex_account = upsert_brex_account!(account_id, account_data)

        if brex_account.account_provider.present?
          already_linked_names << account_name
          next
        end

        account = Account.create_and_sync(
          {
            family: family,
            name: account_name,
            balance: 0,
            currency: BrexAccount.currency_for(account_data),
            accountable_type: accountable_type,
            accountable_attributes: BrexAccount.default_accountable_attributes(accountable_type)
          },
          skip_initial_sync: true
        )

        AccountProvider.create!(account: account, provider: brex_account)
        created_accounts << account
      end
    end

    brex_item.sync_later if created_accounts.any?

    LinkAccountsResult.new(
      created_accounts: created_accounts,
      already_linked_names: already_linked_names,
      invalid_account_ids: invalid_account_ids
    )
  end

  def link_existing_account!(account:, brex_account_id:)
    account_data = indexed_accounts[brex_account_id.to_s]
    raise AccountNotFoundError unless account_data

    account_name = BrexAccount.name_for(account_data)
    raise InvalidAccountNameError if account_name.blank?

    brex_account = nil

    ActiveRecord::Base.transaction do
      brex_account = upsert_brex_account!(brex_account_id, account_data)
      raise AccountAlreadyLinkedError if brex_account.account_provider.present?

      AccountProvider.create!(account: account, provider: brex_account)
    end

    brex_item.sync_later

    brex_account
  end

  private

    def provider_error_class
      Provider::Brex::BrexError
    end

    def resolve_item(id)
      BrexItem.resolve_for(family: family, brex_item_id: id)
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

    def fetch_accounts
      provider = brex_item&.brex_provider
      raise NoApiTokenError unless provider.present?

      accounts_data = provider.get_accounts
      accounts_data[:accounts] || []
    end

    def account_offered_as?(account, accountable_type)
      case accountable_type
      when "CreditCard"
        BrexAccount.kind_for(account) == "card"
      when "Depository"
        BrexAccount.kind_for(account) == "cash"
      else
        true
      end
    end

    def indexed_accounts
      accounts.index_by { |account| account.with_indifferent_access[:id].to_s }
    end

    def upsert_brex_account!(account_id, account_data)
      brex_account = brex_item.brex_accounts.find_or_initialize_by(account_id: account_id.to_s)
      brex_account.upsert_brex_snapshot!(account_data)
      brex_account
    end
end
