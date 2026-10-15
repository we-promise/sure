# Status dot, name and status lines on the left of a connection row, its
# actions on the right.
class TradeRepublic::ConnectionRowHeaderComponent < ApplicationComponent
  renders_one :status
  renders_one :details
  renders_one :actions

  def initialize(title:, dot_class:, identifier: nil)
    @title = title
    @dot_class = dot_class
    @identifier = identifier
  end

  attr_reader :title, :dot_class, :identifier
end
