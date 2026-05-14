class Goals::AvatarComponent < ApplicationComponent
  SIZES = {
    "sm" => { box: "w-6 h-6", text: "text-[10px]", radius: "rounded-md" },
    "md" => { box: "w-9 h-9", text: "text-sm", radius: "rounded-lg" },
    "lg" => { box: "w-11 h-11", text: "text-base", radius: "rounded-xl" },
    "xl" => { box: "w-16 h-16", text: "text-2xl", radius: "rounded-2xl" }
  }.freeze

  PALETTE = Goal::COLORS

  # Deterministic color pick from the palette so the same string maps to
  # the same color across processes (Ruby's String#hash is randomized per
  # boot for DoS protection. not stable enough for visual identity).
  def self.color_for(name)
    return PALETTE.first if name.blank?
    PALETTE[Digest::MD5.hexdigest(name).to_i(16) % PALETTE.size]
  end

  def initialize(goal: nil, name: nil, color: nil, icon: nil, size: "md")
    @goal = goal
    @name = name || goal&.name
    @color = color || goal&.color || Goal::COLORS.first
    @icon = icon || goal&.icon
    @size = SIZES.key?(size) ? size : "md"
  end

  attr_reader :color

  # Don't expose @icon via attr_reader. `icon` collides with the global
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
