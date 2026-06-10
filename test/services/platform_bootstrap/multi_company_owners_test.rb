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
      result = nil

      assert_difference -> { Family.count }, 4 do
        assert_difference -> { User.count }, 2 do
          result = MultiCompanyOwners.new(passwords: PASSWORDS).call
        end
      end

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
      custom_onboarded_at = 2.days.ago.change(usec: 0)
      custom_family = Family.create!(name: "Custom holding company", currency: "INR", locale: I18n.default_locale.to_s)

      User.find_by!(email: "adminf0@bookeepz.net").update!(
        first_name: "Custom",
        last_name: "Owner",
        family: custom_family,
        role: :guest,
        onboarded_at: custom_onboarded_at,
        ui_layout: :intro,
        show_sidebar: false,
        show_ai_sidebar: false
      )

      updated_passwords = {
        "adminF0@bookeepz.net" => "OwnerF0New!2026",
        "adminF1@bookeepz.net" => "OwnerF1New!2026"
      }

      result = nil

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          result = MultiCompanyOwners.new(passwords: updated_passwords).call
        end
      end

      assert result.success?
      assert_equal 1, User.where(email: "adminf0@bookeepz.net").count
      assert_equal 1, User.where(email: "adminf1@bookeepz.net").count

      COMPANY_NAMES.each do |name|
        assert_equal 1, Family.where(name: name).count, "expected no duplicate family named #{name}"
      end

      admin_f0 = User.find_by!(email: "adminf0@bookeepz.net")
      admin_f1 = User.find_by!(email: "adminf1@bookeepz.net")
      primary_family = Family.find_by!(name: "Risingstone infra pvt ltd")

      assert admin_f0.authenticate("OwnerF0New!2026")
      assert admin_f1.authenticate("OwnerF1New!2026")
      assert_equal "super_admin", admin_f0.role
      assert_equal "super_admin", admin_f1.role
      assert_equal primary_family, admin_f0.family
      assert_equal "Custom", admin_f0.first_name
      assert_equal "Owner", admin_f0.last_name
      assert_equal custom_onboarded_at, admin_f0.onboarded_at
      assert_equal "intro", admin_f0.ui_layout
      assert_not admin_f0.show_sidebar
      assert_not admin_f0.show_ai_sidebar
    end

    test "requests advisory lock before bootstrap writes" do
      service = MultiCompanyOwners.new(passwords: PASSWORDS)
      primary_family = Family.new(name: "Risingstone infra pvt ltd")
      families = { "Risingstone infra pvt ltd" => primary_family }
      sequence = sequence("multi-company bootstrap lock")

      service.expects(:acquire_advisory_lock!).once.in_sequence(sequence)
      service.expects(:upsert_families).once.in_sequence(sequence).returns(families)
      service.expects(:upsert_users).with(primary_family: primary_family).once.in_sequence(sequence).returns([])

      result = service.call

      assert_equal [ primary_family ], result.families
      assert_empty result.users
    end

    test "PostgreSQL advisory lock executes transaction lock SQL" do
      service = MultiCompanyOwners.new(passwords: PASSWORDS)
      connection = ActiveRecord::Base.connection
      expected_sql = ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_advisory_xact_lock(?)", MultiCompanyOwners::ADVISORY_LOCK_KEY ]
      )

      connection.stubs(:adapter_name).returns("PostgreSQL")
      connection.expects(:execute).with(expected_sql).once

      service.send(:acquire_advisory_lock!)
    end

    test "advisory lock is skipped for non-PostgreSQL adapters" do
      service = MultiCompanyOwners.new(passwords: PASSWORDS)
      connection = ActiveRecord::Base.connection

      connection.stubs(:adapter_name).returns("SQLite")
      connection.expects(:execute).never

      service.send(:acquire_advisory_lock!)
    end

    test "dry run validates but rolls back changes" do
      result = nil

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          result = MultiCompanyOwners.new(passwords: PASSWORDS, dry_run: true).call
        end
      end

      assert result.success?
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
      assert_dry_run_previews result
    end

    test "rolls back family writes when owner save fails" do
      invalid_user = User.new(email: "adminf0@bookeepz.net")
      invalid_user.errors.add(:base, "forced failure")
      User.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(invalid_user))

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          assert_raises(ActiveRecord::RecordInvalid) do
            MultiCompanyOwners.new(passwords: PASSWORDS).call
          end
        end
      end

      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
    end

    test "accepts double quote as a special password character" do
      quoted_passwords = {
        "adminF0@bookeepz.net" => "OwnerF0Pass\"2026",
        "adminF1@bookeepz.net" => "OwnerF1Pass\"2026"
      }

      result = nil

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          result = MultiCompanyOwners.new(passwords: quoted_passwords, dry_run: true).call
        end
      end

      assert result.success?
      assert_dry_run_previews result
    end

    test "rejects missing password for required owner" do
      error = nil

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          error = assert_raises(ArgumentError) do
            MultiCompanyOwners.new(passwords: { "adminF0@bookeepz.net" => "OwnerF0Pass!2026" }).call
          end
        end
      end

      assert_includes error.message, "Missing password for adminF1@bookeepz.net"
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
    end

    test "rejects weak passwords before writing records" do
      weak_passwords = {
        "adminF0@bookeepz.net" => "weak",
        "adminF1@bookeepz.net" => "OwnerF1Pass!2026"
      }

      error = nil

      assert_no_difference -> { Family.count } do
        assert_no_difference -> { User.count } do
          error = assert_raises(ArgumentError) do
            MultiCompanyOwners.new(passwords: weak_passwords).call
          end
        end
      end

      assert_includes error.message, "Password for adminF0@bookeepz.net must be at least 8 characters"
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
    end

    private
      def assert_dry_run_previews(result)
        assert result.families.all? { |family| !family.persisted? && family.id.nil? }
        assert result.users.all? { |user| !user.persisted? && user.id.nil? }
        assert result.users.map(&:family).all? { |family| !family.persisted? && family.id.nil? }
      end
  end
end
