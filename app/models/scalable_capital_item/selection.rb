class ScalableCapitalItem::Selection
  attr_reader :attributes, :broker_account_id

  def initialize(attributes, item:)
    @attributes = attributes
    @broker_account_id = item.broker_account_id
  end

  def key
    "#{attributes.fetch('kind')}:#{attributes.fetch('id')}"
  end

  def portfolio_id
    attributes.fetch("id") if attributes.fetch("kind") == "brokerage"
  end

  def savings_id
    attributes.fetch("id") if attributes.fetch("kind") == "savings"
  end

  def savings_owner_kind
    attributes.fetch("owner_kind")
  end

  def auto_discover_savings?
    false
  end

  def broker_history_start
    checkpoint
  end

  def savings_synced_through
    checkpoint
  end

  def snapshot_attributes
    label = attributes["label"].presence || I18n.t("scalable_capital_items.discover.id_suffix", suffix: attributes.fetch("id").last(4))
    { source_key: key, source_label: label, junior: savings_owner_kind == "junior" }
  end

  def advanced(through)
    attributes.merge("synced_through" => [ checkpoint, through ].compact.max.iso8601)
  end

  private

    def checkpoint
      Time.iso8601(attributes["synced_through"]) if attributes["synced_through"]
    end
end
