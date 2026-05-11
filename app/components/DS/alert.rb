class DS::Alert < DesignSystemComponent
  VARIANTS = %i[info success warning error destructive].freeze

  def initialize(message: nil, title: nil, variant: :info)
    @message = message
    @title = title
    @variant = normalize_variant(variant)
  end

  private
    attr_reader :message, :title, :variant

    def normalize_variant(raw)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      VARIANTS.include?(sym) ? sym : :info
    end

    def container_classes
      base_classes = "flex items-start gap-3 p-4 rounded-lg border"

      variant_classes = case variant
      when :info
        "bg-info/10 border-info/20"
      when :success
        "bg-success/10 border-success/20"
      when :warning
        "bg-warning/10 border-warning/20"
      when :error, :destructive
        "bg-destructive/10 border-destructive/20"
      end

      "#{base_classes} #{variant_classes}"
    end

    def icon_name
      case variant
      when :info
        "info"
      when :success
        "check-circle"
      when :warning
        "alert-triangle"
      when :error, :destructive
        "x-circle"
      end
    end

    def icon_color
      case variant
      when :success
        "success"
      when :warning
        "warning"
      when :error, :destructive
        "destructive"
      else
        "info"
      end
    end
end
