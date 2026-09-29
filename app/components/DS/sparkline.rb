# A small labeled line-with-dots chart: one polyline over evenly spaced
# points, a dot per point (hollow when the value is zero), and a label under
# every other point.
#
# Extracted from the bill detail's twelve-month payment history so views stop
# hand-rolling SVG (raw SVG belongs in DS primitives). The component owns the
# geometry; the caller passes dated values and sets the color via a text-*
# class on `css`, which the strokes and fills pick up through currentColor.
class DS::Sparkline < DesignSystemComponent
  WIDTH = 336
  HEIGHT = 84
  LEFT_PAD = 10
  SPAN = 316.0
  BASELINE_Y = 62
  VALUE_HEIGHT = 48
  LABEL_Y = 80

  attr_reader :series, :aria_label, :css, :label_format

  # series: [ [Date, Numeric], ... ] in display order.
  def initialize(series:, aria_label:, css: "w-full text-success", label_format: "%b")
    @series = series
    @aria_label = aria_label
    @css = css
    @label_format = label_format
  end

  def points
    @points ||= series.each_with_index.map do |(_label, value), index|
      [ x_at(index), BASELINE_Y - (value.to_f / peak) * VALUE_HEIGHT, value ]
    end
  end

  def polyline_points
    points.map { |x, y, _| "#{x.round(1)},#{y.round(1)}" }.join(" ")
  end

  # Every other label keeps the axis readable at sparkline width.
  def labels
    series.each_with_index.filter_map do |(label, _value), index|
      next unless index.even?

      [ x_at(index).round(1), I18n.l(label, format: label_format) ]
    end
  end

  private
    def x_at(index)
      LEFT_PAD + index * (SPAN / [ series.size - 1, 1 ].max)
    end

    def peak
      @peak ||= [ series.map(&:last).max, 1 ].max.to_f
    end
end
