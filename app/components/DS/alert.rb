class DS::Alert < DesignSystemComponent
  VARIANTS = %i[info success warning error destructive].freeze
  LIVE_MODES = %i[none status alert].freeze

  def initialize(message: nil, title: nil, variant: :info, live: :none)
    @message = message
    @title = title
    @variant = normalize_variant(variant)
    @live = normalize_live(live)
  end

  private
    attr_reader :message, :title, :variant, :live

    def normalize_variant(raw)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      VARIANTS.include?(sym) ? sym : :info
    end

    def normalize_live(raw)
      sym = raw.respond_to?(:to_sym) ? raw.to_sym : nil
      case sym
      when :polite then :status
      when :assertive then :alert
      when *LIVE_MODES then sym
      else :none
      end
    end

    def container_classes
      base_classes = "p-4 rounded-lg border"

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

    def aria_role
      case live
      when :status then "status"
      when :alert then "alert"
      end
    end

    def variant_label
      I18n.t("ds.alert.variants.#{variant}")
    end

    def title_id
      @title_id ||= "DS-alert-title-#{SecureRandom.hex(4)}"
    end
end
