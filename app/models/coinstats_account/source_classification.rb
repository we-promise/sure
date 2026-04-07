module CoinstatsAccount::SourceClassification
  extend ActiveSupport::Concern

  def wallet_source?
    payload = raw_payload.to_h.with_indifferent_access
    payload[:source] == "wallet" || (payload[:address].present? && payload[:blockchain].present?)
  end

  def exchange_source?
    exchange_source_for?(raw_payload)
  end

  def exchange_portfolio_account?
    payload = raw_payload.to_h.with_indifferent_access
    exchange_source_for?(payload) && (
      ActiveModel::Type::Boolean.new.cast(payload[:portfolio_account]) ||
      payload[:coins].is_a?(Array)
    )
  end

  def legacy_exchange_asset_account?
    exchange_source? && !exchange_portfolio_account?
  end

  def fiat_asset?(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    return false if exchange_portfolio_source_for?(payload)

    metadata = asset_metadata(payload)

    ActiveModel::Type::Boolean.new.cast(metadata[:isFiat]) ||
      ActiveModel::Type::Boolean.new.cast(payload[:isFiat]) ||
      fiat_identifier?(metadata[:identifier]) ||
      fiat_identifier?(payload[:coinId]) ||
      fiat_identifier?(account_id)
  end

  def crypto_asset?
    !fiat_asset?
  end

  private
    def exchange_source_for?(payload)
      payload = payload.to_h.with_indifferent_access
      payload[:source] == "exchange" || payload[:portfolio_id].present?
    end

    def exchange_portfolio_source_for?(payload)
      payload = payload.to_h.with_indifferent_access
      exchange_source_for?(payload) && (
        ActiveModel::Type::Boolean.new.cast(payload[:portfolio_account]) ||
        payload[:coins].is_a?(Array)
      )
    end
end
