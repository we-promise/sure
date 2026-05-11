class Savings::ProgressRingComponent < ApplicationComponent
  SIZE = 180
  STROKE = 14
  RADIUS = (SIZE - STROKE) / 2.0
  CIRCUMFERENCE = 2 * Math::PI * RADIUS

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def percent
    [ [ goal.progress_percent.to_i, 0 ].max, 100 ].min
  end

  def offset
    CIRCUMFERENCE * (1 - percent / 100.0)
  end

  def stroke_color
    case percent
    when 0...25 then "var(--color-gray-400)"
    when 25...75 then "var(--color-blue-500)"
    else "var(--color-green-600)"
    end
  end

  def current_label
    goal.current_balance_money.format
  end

  def target_label
    goal.target_amount_money.format
  end
end
