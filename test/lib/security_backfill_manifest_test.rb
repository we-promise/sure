# frozen_string_literal: true

require "test_helper"

class SecurityBackfillManifestTest < ActiveSupport::TestCase
  setup do
    skip "Encryption not configured" unless User.encryption_ready?
  end

  test "lists exactly the encrypted attributes of every model" do
    Rails.application.eager_load!

    declared = ActiveRecord::Base.descendants.each_with_object({}) do |model, map|
      next if model.abstract_class? || model.name.nil? || model.name.safe_constantize != model
      next if SecurityBackfillManifest::IGNORED.include?(model.name)
      next if SecurityBackfillManifest::HANDLED_SEPARATELY.include?(model.name)

      fields = model.encrypted_attributes.to_a
      map[model.name] = fields.sort if fields.any?
    end
    listed = SecurityBackfillManifest::FIELDS.transform_values(&:sort)

    assert_equal declared.sort.to_h, listed.sort.to_h,
      "security:backfill_encryption must cover every encrypted attribute; update SecurityBackfillManifest::FIELDS"
  end
end
