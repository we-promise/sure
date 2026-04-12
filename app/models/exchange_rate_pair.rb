class ExchangeRatePair < ApplicationRecord
  validates :from_currency, :to_currency, presence: true
  validates :from_currency, uniqueness: { scope: :to_currency, case_sensitive: false }

  def self.for_pair(from:, to:)
    pair = find_or_create_by!(from_currency: from, to_currency: to)
    current_provider = Setting.exchange_rate_provider.to_s
    if pair.provider_name != current_provider && pair.first_provider_rate_on.present?
      pair.update_columns(first_provider_rate_on: nil, provider_name: current_provider)
      pair.reload
    end
    pair
  rescue ActiveRecord::RecordNotUnique
    find_by!(from_currency: from, to_currency: to)
  end

  def self.record_first_provider_rate_on(from:, to:, date:)
    return if date.blank?

    pair = for_pair(from: from, to: to)
    current_provider = Setting.exchange_rate_provider.to_s

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
