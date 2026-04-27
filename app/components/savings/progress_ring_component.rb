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

  # Hex strokes (CSS vars don't always resolve in raw SVG `stroke=` attrs;
  # Sure's other progress circle works around this with inline `style=`).
  def fill_stroke_color
    return color if color.present?
    case percent
    when 0..24   then "#9CA3AF"  # gray-400 — barely started
    when 25..74  then "#3B82F6"  # blue-500 — in progress
    else              "#10B981"  # emerald-500 — near / at target
    end
  end
end
