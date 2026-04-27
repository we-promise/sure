class Savings::ProgressRingComponent < ApplicationComponent
  attr_reader :percent, :size, :stroke, :color, :label_lines

  # `label_lines` is an array of strings rendered as <tspan> rows inside the
  # ring. Defaults to `["#{percent}%"]` so existing call sites (goal cards,
  # budget summary card) keep their compact percent display. The goal show
  # page passes a richer ["$1,250", "of $6,000", "21%"] for the larger ring.
  def initialize(percent:, size: 80, stroke: 6, color: nil, label_lines: nil)
    @percent = percent.to_i.clamp(0, 100)
    @size = size
    @stroke = stroke
    @color = color
    @label_lines = Array(label_lines || [ "#{@percent}%" ])
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

  # CSS vars resolve fine inside an inline `style=` attribute (Sure's
  # shared/_progress_circle uses the same trick), unlike raw SVG `stroke=`
  # attribute values where the spec is fussier.
  def fill_stroke_color
    return color if color.present?
    case percent
    when 0..24   then "var(--color-gray-400)"   # barely started
    when 25..74  then "var(--color-blue-500)"   # in progress
    else              "var(--color-success)"    # near or at target
    end
  end
end
