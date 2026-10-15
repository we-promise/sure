# Adds a Trade Republic connection, shown inline for the first one and in a
# dialog once connections exist.
class TradeRepublic::NewConnectionFormComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  # `in_drawer` tells create to close the drawer once the connection is
  # added; the first connection is added from a panel that may itself be
  # shown in the drawer, which must stay open for the QR code.
  def initialize(pending_connection:, in_drawer: false)
    @pending_connection = pending_connection
    @in_drawer = in_drawer
  end

  attr_reader :pending_connection, :in_drawer
end
