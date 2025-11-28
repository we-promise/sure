module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    def set_breadcrumbs
      key = "shared.breadcrumbs.#{controller_name}"
      label = I18n.t(key, default: controller_name.titleize)

      @breadcrumbs = [
        [ "Home", root_path ],
        [ label, nil ]
      ]
    end
end
