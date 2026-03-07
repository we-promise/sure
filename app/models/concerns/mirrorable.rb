# frozen_string_literal: true

# Mirrorable concern for ActiveRecord models
#
# This concern hooks into the model lifecycle to enqueue background jobs
# that mirror database writes to an external PostgreSQL database.
#
# The mirroring is non-blocking and uses after_commit callbacks to ensure
# the local transaction is complete before enqueuing the mirror job.
#
module Mirrorable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_mirror_create, on: :create, if: :mirror_enabled?
    after_commit :enqueue_mirror_update, on: :update, if: :mirror_enabled?
    after_commit :enqueue_mirror_destroy, on: :destroy, if: :mirror_enabled?
  end

  private

    def mirror_enabled?
      ENV["DATABASE_MIRROR_ENABLED"] == "true" && !self.class.mirror_excluded?
    end

    def enqueue_mirror_create
      DatabaseMirrorJob.perform_later(
        operation: :create,
        model_class: self.class.name,
        primary_key: self[self.class.primary_key],
        attributes: mirror_attributes
      )
    end

    def enqueue_mirror_update
      DatabaseMirrorJob.perform_later(
        operation: :update,
        model_class: self.class.name,
        primary_key: self[self.class.primary_key],
        attributes: mirror_attributes
      )
    end

    def enqueue_mirror_destroy
      DatabaseMirrorJob.perform_later(
        operation: :destroy,
        model_class: self.class.name,
        primary_key: self[self.class.primary_key],
        attributes: {}
      )
    end

    # Serialize attributes for the job payload
    # Excludes associations and handles complex types
    def mirror_attributes
      attributes.transform_values do |value|
        case value
        when ActiveSupport::TimeWithZone, Time, DateTime
          value.iso8601
        when Date
          value.to_s
        when BigDecimal
          value.to_s("F")
        when Array, Hash
          value.to_json
        else
          value
        end
      end
    end

  class_methods do
    # Models can opt-out of mirroring by calling `exclude_from_mirror`
    def exclude_from_mirror
      @mirror_excluded = true
    end

    def mirror_excluded?
      @mirror_excluded == true
    end
  end
end
