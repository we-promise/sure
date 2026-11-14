class ExchangeRatePair < ApplicationRecord
  validates :from_currency, :to_currency, presence: true

  def self.for_pair(from:, to:, provider_name: nil)
    pair = find_or_create_by!(from_currency: from, to_currency: to)
    current_provider = provider_name || ExchangeRate.provider_name

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

  def self.record_first_provider_rate_on(from:, to:, date:, provider_name: nil)
    return if date.blank?

    current_provider = provider_name || ExchangeRate.provider_name
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
