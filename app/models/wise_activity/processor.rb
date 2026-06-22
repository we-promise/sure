# frozen_string_literal: true

class WiseActivity::Processor
  JAR_ACTIVITY_TYPES = %w[INTERBALANCE BALANCE_CASHBACK BALANCE_ASSET_FEE].freeze

  def initialize(activity, wise_account:)
    @activity = activity.with_indifferent_access
    @wise_account = wise_account
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseActivity::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "wise",
      extra: extra
    )
  rescue ArgumentError => e
    Rails.logger.error "WiseActivity::Processor - Validation error for activity #{safe_id}: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WiseActivity::Processor - Error for activity #{safe_id}: #{e.class} - #{e.message}"
    raise StandardError, e.message
  end

  private

    attr_reader :activity, :wise_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= wise_account.current_account
    end

    # INTERBALANCE uses resource_id so both sides can be matched for Transfer linking.
    # Other activity types use the opaque activity id.
    def external_id
      if activity_type == "INTERBALANCE"
        side = wise_account.jar? ? "inflow" : "outflow"
        "wise_interbalance_#{resource_id}_#{side}"
      else
        "wise_activity_#{activity[:id]}"
      end
    end

    def safe_id
      activity[:id].presence || "unknown"
    end

    def activity_type
      activity[:type].to_s
    end

    def resource_id
      activity.dig(:resource, :id).to_s
    end

    # Expenses (outflow) → positive in Sure.
    # Incomes (inflow / interest) → negative in Sure.
    def amount
      raw = parse_amount
      case activity_type
      when "BALANCE_ASSET_FEE"
        raw.abs   # fee = outflow = positive (expense)
      when "INTERBALANCE"
        if wise_account.jar?
          # JAR perspective: "To Jar" = deposit (income, negative)
          deposit_direction? ? -raw.abs : raw.abs
        else
          # STANDARD perspective: "To Jar" = outflow (expense, positive)
          deposit_direction? ? raw.abs : -raw.abs
        end
      else
        -raw.abs  # BALANCE_CASHBACK / interest → income (negative)
      end
    end

    # True when the activity title indicates money flowing INTO the JAR.
    def deposit_direction?
      title = strip_html(activity[:title]).downcase
      title.start_with?("to") || title.include?("received") || title.include?("added")
    end

    def currency
      parse_currency || wise_account.currency
    end

    def name
      jar_name = wise_account.jar? ? (wise_account.raw_payload&.dig("name") || "Jar") : nil

      case activity_type
      when "INTERBALANCE"
        if wise_account.jar?
          deposit_direction? ? I18n.t("wise_items.activities.jar_deposit") : I18n.t("wise_items.activities.jar_withdrawal")
        else
          deposit_direction? ? I18n.t("wise_items.activities.transfer_to_jar", jar: jar_name_for_standard) : I18n.t("wise_items.activities.transfer_from_jar", jar: jar_name_for_standard)
        end
      when "BALANCE_CASHBACK"
        I18n.t("wise_items.activities.interest")
      when "BALANCE_ASSET_FEE"
        I18n.t("wise_items.activities.asset_fee")
      else
        strip_html(activity[:title]).strip.presence ||
          I18n.t("wise_items.activities.default_name")
      end
    end

    def jar_name_for_standard
      activity[:title].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last || "Jar"
    end

    def date
      raw = activity[:createdOn].presence
      raise ArgumentError, "Activity missing createdOn" unless raw
      DateTime.parse(raw).to_date
    end

    def extra
      {
        wise: {
          activity_id: activity[:id],
          activity_type: activity_type,
          resource_type: activity.dig(:resource, :type),
          resource_id: resource_id.presence
        }.compact
      }
    end

    # Parses the numeric amount from strings like:
    #   "1,000 EUR"                          → 1000.0
    #   "<positive>+ 1.12 EUR</positive>"    → 1.12
    #   "0.83 EUR"                           → 0.83
    def parse_amount
      stripped = strip_html(activity[:primaryAmount]).strip
      stripped.scan(/[\d,]+\.?\d*/).first.to_s.delete(",").to_d
    end

    def parse_currency
      activity[:primaryAmount].to_s.scan(/\b[A-Z]{3}\b/).first
    end

    def strip_html(str)
      ActionController::Base.helpers.strip_tags(str.to_s)
    end
end
