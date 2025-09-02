module EnableBankingItem::Provided
  extend ActiveSupport::Concern

  def enable_banking_provider
    @enable_banking_provider ||= Provider::Registry.get_provider(:enable_banking)
  end
end
