# Adds a Trade Republic connection, shown inline for the first one and in a
# dialog once connections exist.
class TradeRepublic::NewConnectionFormComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(item:)
    @item = item
  end

  attr_reader :item
end
