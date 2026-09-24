class ExchangeRatePair < ApplicationRecord
  validates :from_currency, :to_currency, presence: true

  EARLIEST_PROVIDER_DATE_COLUMNS = %i[first_provider_rate_on provider_history_checked_from].freeze

  def self.for_pair(from:, to:, provider_name: nil)
    pair = find_or_create_by!(from_currency: from, to_currency: to)
    current_provider = provider_name || resolve_provider_name
    return pair unless current_provider == resolve_provider_name

    if pair.provider_name != current_provider
      ExchangeRatePair.where(id: pair.id, provider_name: pair.provider_name).update_all(
        first_provider_rate_on: nil,
        provider_history_checked_from: nil,
        provider_name: current_provider,
        updated_at: Time.current
      )
      pair.reload
    end

    pair
  rescue ActiveRecord::RecordNotUnique
    find_by!(from_currency: from, to_currency: to)
  end

  # Resolves the runtime provider name the same way as ExchangeRate::Provided.provider:
  # ENV takes precedence over the DB Setting.
  def self.resolve_provider_name
    (ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider).to_s
  end

  def self.record_first_provider_rate_on(from:, to:, date:, provider_name: nil, pair: nil)
    record_earliest_provider_date_on(:first_provider_rate_on, from:, to:, date:, provider_name:, pair:)
  end

  # Tracks the earliest date requested from this provider.
  # Unlike first_provider_rate_on, this may precede the earliest returned rate.
  def self.record_provider_history_checked_from(from:, to:, date:, provider_name: nil, pair: nil)
    record_earliest_provider_date_on(:provider_history_checked_from, from:, to:, date:, provider_name:, pair:)
  end

  def self.record_earliest_provider_date_on(column, from:, to:, date:, provider_name: nil, pair: nil)
    return if date.blank?
    return unless EARLIEST_PROVIDER_DATE_COLUMNS.include?(column)

    current_provider = provider_name || resolve_provider_name
    return unless current_provider == resolve_provider_name

    pair ||= for_pair(from: from, to: to, provider_name: current_provider)
    return unless pair.provider_name == current_provider

    ExchangeRatePair
      .where(id: pair.id, provider_name: current_provider)
      .where("#{column} IS NULL OR #{column} > ?", date)
      .update_all(
        column => date,
        updated_at: Time.current
      )
  end
  private_class_method :record_earliest_provider_date_on
end
