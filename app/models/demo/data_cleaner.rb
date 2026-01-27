class Demo::DataCleaner
  DEMO_GENERATED_KEY = "demo_generated".freeze

  def initialize(include_all: false); end

  def destroy_demo_data!
    families_with_demo_marker.find_each(&:destroy!)
    puts "Demo data cleared"
  end

  def destroy_everything!
    destroy_shared_records!
    puts "Data cleared"
  end

  private
    def families_with_demo_marker
      family_ids = User.where("preferences ->> ? = ?", DEMO_GENERATED_KEY, "true").select(:family_id).distinct
      Family.where(id: family_ids)
    end

    def destroy_shared_records!
      # Clear SSO audit logs first (they reference users)
      SsoAuditLog.destroy_all

      Family.destroy_all
      Setting.destroy_all
      InviteCode.destroy_all
      ExchangeRate.destroy_all
      Security.destroy_all
      Security::Price.destroy_all
    end
end
