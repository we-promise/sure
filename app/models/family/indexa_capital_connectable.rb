module Family::IndexaCapitalConnectable
  extend ActiveSupport::Concern

  included do
    has_many :indexa_capital_items, dependent: :destroy
  end

  def can_connect_indexa_capital?
    # Families can configure their own IndexaCapital credentials
    true
  end

  def create_indexa_capital_item!(username:, document:, password:, item_name: nil)
    indexa_capital_item = indexa_capital_items.create!(
      name: item_name || "Indexa Capital Connection",
      username: username,
      document: document,
      password: password
    )

    indexa_capital_item.sync_later

    indexa_capital_item
  end

  def has_indexa_capital_credentials?
    indexa_capital_items.where.not(api_token: [ nil, "" ]).or(
      indexa_capital_items.where.not(username: [ nil, "" ])
                          .where.not(document: [ nil, "" ])
                          .where.not(password: [ nil, "" ])
    ).exists?
  end
end
