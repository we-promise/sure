# The bordered row a Trade Republic connection or a new connection's login
# sits in, like the connection rows of the Enable Banking panel.
class TradeRepublic::ConnectionRowComponent < ApplicationComponent
  def initialize(id:, data: {})
    @id = id
    @data = data
  end

  attr_reader :id, :data
end
