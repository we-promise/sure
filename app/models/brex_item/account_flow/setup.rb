# frozen_string_literal: true

class BrexItem::AccountFlow
  module Setup
    def import_accounts_from_api_if_needed
      raise NoApiTokenError unless brex_item&.credentials_configured?

      available_accounts = fetch_accounts
      return nil if available_accounts.empty?

      existing_accounts = brex_item.brex_accounts.index_by(&:account_id)

      available_accounts.each do |account_data|
        account_id = account_data.with_indifferent_access[:id].to_s
        account_name = BrexAccount.name_for(account_data)
        next if account_id.blank? || account_name.blank?

        brex_account = existing_accounts[account_id]
        next if brex_account.present? && !brex_account_snapshot_changed?(brex_account, account_data)

        upsert_brex_account!(account_id, account_data)
      end

      nil
    end

    def unlinked_brex_accounts
      brex_item.brex_accounts
               .left_joins(:account_provider)
               .where(account_providers: { id: nil })
    end

    def account_type_options
      supported_types = Provider::BrexAdapter.supported_account_types
      account_type_keys = {
        "depository" => "Depository",
        "credit_card" => "CreditCard",
        "investment" => "Investment",
        "loan" => "Loan",
        "other_asset" => "OtherAsset"
      }

      options = account_type_keys.filter_map do |key, type|
        next unless supported_types.include?(type)

        [ I18n.t("brex_items.setup_accounts.account_types.#{key}"), type ]
      end

      [ [ I18n.t("brex_items.setup_accounts.account_types.skip"), "skip" ] ] + options
    end

    def displayable_account_type_options
      account_type_options.reject { |_, type| type == "skip" }
    end

    def subtype_options
      supported_types = Provider::BrexAdapter.supported_account_types
      all_subtype_options = {
        "Depository" => {
          label: I18n.t("brex_items.setup_accounts.subtype_labels.depository"),
          options: translate_subtypes("depository", Depository::SUBTYPES)
        },
        "CreditCard" => {
          label: I18n.t("brex_items.setup_accounts.subtype_labels.credit_card"),
          options: [],
          message: I18n.t("brex_items.setup_accounts.subtype_messages.credit_card")
        },
        "Investment" => {
          label: I18n.t("brex_items.setup_accounts.subtype_labels.investment"),
          options: translate_subtypes("investment", Investment::SUBTYPES)
        },
        "Loan" => {
          label: I18n.t("brex_items.setup_accounts.subtype_labels.loan"),
          options: translate_subtypes("loan", Loan::SUBTYPES)
        },
        "OtherAsset" => {
          label: I18n.t("brex_items.setup_accounts.subtype_labels.other_asset", default: "Other asset"),
          options: [],
          message: I18n.t("brex_items.setup_accounts.subtype_messages.other_asset")
        }
      }

      all_subtype_options.slice(*supported_types)
    end

    def complete_setup!(account_types:, account_subtypes:)
      created_accounts = []
      skipped_count = 0
      valid_types = Provider::BrexAdapter.supported_account_types
      failed_count = 0

      submitted_brex_accounts = brex_item.brex_accounts
                                      .where(id: account_types.keys)
                                      .includes(:account_provider)
                                      .index_by { |brex_account| brex_account.id.to_s }

      account_types.each do |brex_account_id, selected_type|
        if selected_type == "skip" || selected_type.blank?
          skipped_count += 1
          next
        end

        unless valid_types.include?(selected_type)
          Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Brex account #{brex_account_id}")
          skipped_count += 1
          next
        end

        brex_account = submitted_brex_accounts[brex_account_id.to_s]
        unless brex_account
          Rails.logger.warn("Brex account #{brex_account_id} not found for item #{brex_item.id}")
          next
        end

        if brex_account.account_provider.present?
          Rails.logger.info("Brex account #{brex_account_id} already linked, skipping")
          next
        end

        selected_subtype = selected_subtype_for(
          selected_type: selected_type,
          submitted_subtype: account_subtypes[brex_account_id]
        )

        begin
          ActiveRecord::Base.transaction do
            account = Account.create_and_sync(
              {
                family: family,
                name: brex_account.name,
                balance: brex_account.current_balance || 0,
                currency: brex_account.currency.presence || family.currency,
                accountable_type: selected_type,
                accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
              },
              skip_initial_sync: true
            )

            AccountProvider.create!(account: account, provider: brex_account)
            created_accounts << account
          end
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
          failed_count += 1
          Rails.logger.error("Brex account setup failed for #{brex_account_id}: #{e.class} - #{e.message}")
          Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
        end
      end

      brex_item.sync_later if created_accounts.any?

      SetupResult.new(created_accounts: created_accounts, skipped_count: skipped_count, failed_count: failed_count)
    end

    def import_accounts_with_user_facing_error
      import_accounts_from_api_if_needed
    rescue NoApiTokenError
      I18n.t("brex_items.setup_accounts.no_api_token")
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex API error: #{e.message}")
      I18n.t("brex_items.setup_accounts.api_error", message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching Brex accounts: #{e.class}: #{e.message}")
      I18n.t("brex_items.setup_accounts.api_error", message: I18n.t("brex_items.errors.unexpected_error"))
    end

    def complete_setup_result(account_types:, account_subtypes:)
      result = complete_setup!(account_types: account_types, account_subtypes: account_subtypes)

      SetupCompletion.new(success: result.failed_count.zero? && result.created_count.positive?, message: setup_notice(result))
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("Brex account setup failed: #{e.class} - #{e.message}")
      Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
      SetupCompletion.new(
        success: false,
        message: I18n.t("brex_items.complete_account_setup.creation_failed", error: e.message)
      )
    rescue StandardError => e
      Rails.logger.error("Brex account setup failed unexpectedly: #{e.class} - #{e.message}")
      Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
      SetupCompletion.new(
        success: false,
        message: I18n.t(
          "brex_items.complete_account_setup.creation_failed",
          error: I18n.t("brex_items.complete_account_setup.unexpected_error")
        )
      )
    end

  private

    def setup_notice(result)
      if result.failed_count.positive? && result.created_count.positive?
        I18n.t("brex_items.complete_account_setup.partial_success", created_count: result.created_count, failed_count: result.failed_count)
      elsif result.skipped_count.positive? && result.created_count.positive?
        I18n.t("brex_items.complete_account_setup.partial_skipped", created_count: result.created_count, skipped_count: result.skipped_count)
      elsif result.failed_count.positive?
        I18n.t("brex_items.complete_account_setup.creation_failed_count", count: result.failed_count)
      elsif result.created_count.positive?
        I18n.t("brex_items.complete_account_setup.success", count: result.created_count)
      elsif result.skipped_count.positive?
        I18n.t("brex_items.complete_account_setup.all_skipped")
      else
        I18n.t("brex_items.complete_account_setup.no_accounts")
      end
    end

    def brex_account_snapshot_changed?(brex_account, account_data)
      snapshot = account_data.with_indifferent_access
      balances = snapshot.slice(:current_balance, :available_balance, :account_limit)

      expected = {
        account_kind: BrexAccount.kind_for(snapshot),
        account_status: snapshot[:status],
        account_type: snapshot[:type],
        available_balance: BrexAccount.money_to_decimal(balances[:available_balance]),
        current_balance: BrexAccount.money_to_decimal(balances[:current_balance]),
        account_limit: BrexAccount.money_to_decimal(balances[:account_limit]),
        currency: BrexAccount.currency_code_from_money(balances[:current_balance] || balances[:available_balance] || balances[:account_limit]),
        name: BrexAccount.name_for(snapshot),
        raw_payload: BrexAccount.sanitize_payload(account_data)
      }

      expected.any? { |attribute, value| brex_account.public_send(attribute) != value }
    end

    def translate_subtypes(type_key, subtypes_hash)
      subtypes_hash.map do |key, value|
        [
          I18n.t("brex_items.setup_accounts.subtypes.#{type_key}.#{key}", default: value[:long] || key.to_s.humanize),
          key
        ]
      end
    end

    def selected_subtype_for(selected_type:, submitted_subtype:)
      return CreditCard::DEFAULT_SUBTYPE if selected_type == "CreditCard" && submitted_subtype.blank?
      return Depository::DEFAULT_SUBTYPE if selected_type == "Depository" && submitted_subtype.blank?

      submitted_subtype
    end
  end
end
