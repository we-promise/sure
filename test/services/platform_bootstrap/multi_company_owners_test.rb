require "test_helper"

module PlatformBootstrap
  class MultiCompanyOwnersTest < ActiveSupport::TestCase
    PASSWORDS = {
      "adminF0@bookeepz.net" => "OwnerF0Pass!2026",
      "adminF1@bookeepz.net" => "OwnerF1Pass!2026"
    }.freeze

    COMPANY_NAMES = [
      "Risingstone infra pvt ltd",
      "Risingstone ventures pvt ltd",
      "Risingstone projects pvt Ltd",
      "Mahetel pvt ltd"
    ].freeze

    test "creates four company families and two super admin owners" do
      result = MultiCompanyOwners.new(passwords: PASSWORDS).call

      assert result.success?

      COMPANY_NAMES.each do |name|
        assert_equal 1, Family.where(name: name).count, "expected one family named #{name}"
      end

      admin_f0 = User.find_by!(email: "adminf0@bookeepz.net")
      admin_f1 = User.find_by!(email: "adminf1@bookeepz.net")
      primary_family = Family.find_by!(name: "Risingstone infra pvt ltd")

      assert_equal "super_admin", admin_f0.role
      assert_equal "super_admin", admin_f1.role
      assert_equal primary_family, admin_f0.family
      assert_equal primary_family, admin_f1.family
      assert_equal "F0-SU-1", admin_f0.first_name
      assert_equal "F0-SU-2", admin_f1.first_name
      assert admin_f0.authenticate("OwnerF0Pass!2026")
      assert admin_f1.authenticate("OwnerF1Pass!2026")
    end

    test "rerun updates existing records without duplicating families or users" do
      MultiCompanyOwners.new(passwords: PASSWORDS).call

      updated_passwords = {
        "adminF0@bookeepz.net" => "OwnerF0New!2026",
        "adminF1@bookeepz.net" => "OwnerF1New!2026"
      }

      result = MultiCompanyOwners.new(passwords: updated_passwords).call

      assert result.success?
      assert_equal 1, User.where(email: "adminf0@bookeepz.net").count
      assert_equal 1, User.where(email: "adminf1@bookeepz.net").count

      COMPANY_NAMES.each do |name|
        assert_equal 1, Family.where(name: name).count, "expected no duplicate family named #{name}"
      end

      admin_f0 = User.find_by!(email: "adminf0@bookeepz.net")
      admin_f1 = User.find_by!(email: "adminf1@bookeepz.net")

      assert admin_f0.authenticate("OwnerF0New!2026")
      assert admin_f1.authenticate("OwnerF1New!2026")
      assert_equal "super_admin", admin_f0.role
      assert_equal "super_admin", admin_f1.role
    end

    test "dry run validates but rolls back changes" do
      result = MultiCompanyOwners.new(passwords: PASSWORDS, dry_run: true).call

      assert result.success?
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
    end

    test "rejects missing password for required owner" do
      error = assert_raises(ArgumentError) do
        MultiCompanyOwners.new(passwords: { "adminF0@bookeepz.net" => "OwnerF0Pass!2026" }).call
      end

      assert_includes error.message, "Missing password for adminF1@bookeepz.net"
    end

    test "rejects weak passwords before writing records" do
      weak_passwords = {
        "adminF0@bookeepz.net" => "weak",
        "adminF1@bookeepz.net" => "OwnerF1Pass!2026"
      }

      error = assert_raises(ArgumentError) do
        MultiCompanyOwners.new(passwords: weak_passwords).call
      end

      assert_includes error.message, "Password for adminF0@bookeepz.net must be at least 8 characters"
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
    end
  end
end
