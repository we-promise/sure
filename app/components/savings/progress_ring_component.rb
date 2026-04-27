class Savings::ProgressRingComponent < ApplicationComponent
  attr_reader :percent, :size, :stroke, :color

  def initialize(percent:, size: 80, stroke: 6, color: nil)
    @percent = percent.to_i.clamp(0, 100)
    @size = size
    @stroke = stroke
    @color = color
  end

  def radius
    (size - stroke) / 2.0
  end

  def circumference
    2 * Math::PI * radius
  end

  def offset
    circumference - (circumference * percent / 100.0)
  end

  def stroke_color
    return color if color.present?
    case percent
    when 0..24   then "var(--color-tertiary)"
    when 25..74  then "var(--color-success)"
    else "var(--color-success)"
    end
  end
end
