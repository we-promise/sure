class Envelopes::AvatarComponent < ApplicationComponent
  SIZES = {
    "sm" => { box: "w-6 h-6", text: "text-xs", radius: "rounded-md" },
    "md" => { box: "w-9 h-9", text: "text-sm", radius: "rounded-lg" },
    "lg" => { box: "w-11 h-11", text: "text-base", radius: "rounded-xl" },
    "xl" => { box: "w-16 h-16", text: "text-2xl", radius: "rounded-2xl" }
  }.freeze

  def initialize(envelope: nil, name: nil, color: nil, icon: nil, size: "md")
    @envelope = envelope
    @name = name || envelope&.name
    @color = color || envelope&.color || Envelope::COLORS.first
    @icon = icon || envelope&.icon
    @size = SIZES.key?(size) ? size : "md"
  end

  attr_reader :color

  # Don't expose @icon via attr_reader — `icon` collides with the global
  # icon helper used inside the template.
  def icon_name
    @icon
  end

  def initial
    return "?" if @name.blank?

    @name.strip.first&.upcase || "?"
  end

  def icon_size
    case @size
    when "sm" then "xs"
    when "md" then "sm"
    when "lg" then "md"
    when "xl" then "xl"
    end
  end

  def box_classes
    SIZES[@size][:box]
  end

  def text_classes
    SIZES[@size][:text]
  end

  def radius_classes
    SIZES[@size][:radius]
  end
end
