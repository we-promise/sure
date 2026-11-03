module MoomooItem::Provided
  extend ActiveSupport::Concern

  def moomoo_provider(budget: nil)
    return nil if oauth_client_id.blank?

    Provider::Moomoo.new(client_id: oauth_client_id, budget: budget)
  end
end
