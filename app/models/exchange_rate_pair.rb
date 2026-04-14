class ExchangeRatePair < ApplicationRecord
  validates :from_currency, :to_currency, presence: true

  def self.for_pair(from:, to:, provider_name: nil)
    pair = find_or_create_by!(from_currency: from, to_currency: to)
    current_provider = provider_name || resolve_provider_name

    if pair.provider_name != current_provider && pair.first_provider_rate_on.present?
      ExchangeRatePair
        .where(id: pair.id)
        .where.not(provider_name: current_provider)
        .update_all(first_provider_rate_on: nil, provider_name: current_provider, updated_at: Time.current)
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

  def self.record_first_provider_rate_on(from:, to:, date:, provider_name: nil)
    return if date.blank?

    current_provider = provider_name || resolve_provider_name
    pair = for_pair(from: from, to: to, provider_name: current_provider)

    ExchangeRatePair
      .where(id: pair.id)
      .where("first_provider_rate_on IS NULL OR first_provider_rate_on > ?", date)
      .update_all(
        first_provider_rate_on: date,
        provider_name: current_provider,
        updated_at: Time.current
      )
  end
end
