module ModuleGateable
  extend ActiveSupport::Concern

  included do
    helper_method :module_enabled?
  end

  class_methods do
    def require_module!(name)
      before_action -> { enforce_module!(name) }
    end
  end

  def module_enabled?(name)
    family = Current.family
    return true if family.nil?
    family.module_enabled?(name)
  end

  private
    def enforce_module!(name)
      return if module_enabled?(name)
      redirect_to root_path, alert: I18n.t("modules.not_enabled")
    end
end
