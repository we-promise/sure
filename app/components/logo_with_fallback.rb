# frozen_string_literal: true

# Renders a logo image with a fallback to a FilledIcon when the image fails
# to load (missing blob bytes, corrupt image, or failed remote URL).
#
# @example Basic usage
#   <%= render LogoWithFallback.new(account: account) %>
#
# @example With custom size and color
#   <%= render LogoWithFallback.new(account: account, size: "lg", color: "#ff0000") %>
class LogoWithFallback < ApplicationComponent
  # @param account [Account] The account whose logo to display
  # @param size [String] The size variant: "sm", "md", "lg", or "full"
  # @param color [String, nil] Optional hex color override for the fallback icon
  def initialize(account:, size: "md", color: nil)
    @account = account
    @size = size
    @color = color
  end

  private

    attr_reader :account, :size, :color

    SIZE_CLASSES = {
      "sm" => "w-6 h-6",
      "md" => "w-9 h-9",
      "lg" => "w-10 h-10",
      "full" => "w-full h-full"
    }.freeze

    def size_class
      SIZE_CLASSES[size] || SIZE_CLASSES["md"]
    end

    # FilledIcon has no :full size; render at :lg inside the full-size wrapper.
    def icon_size
      size == "full" ? "lg" : size
    end

    def fallback_icon_color
      color || account.accountable&.color
    end
end
