# The domain side of a generation feature: a domain class that rebuilds itself
# from job arguments, makes the generation and applies the result. Ai::GenerationJob talks only
# to the requester, so it never knows what categorizing or detecting merchants means.
#
#   class Family::AutoCategorizer
#     include Ai::Requester
#     ai_feature :categorize
#
#     def self.from_ai_job(window:, family_id:, **) # job arguments are ids, never records; window: this
#                                                  # job's share of the run (Ai::GenerationRun::Window)
#     def ai_generation                            # the generation for the window's matching items, or
#                                                  # nil when none are left in the run
#     def apply_ai(result)                         # writes through the domain; returns a count
#     def ai_finished(count)                       # once, after the last batch
#     def ai_failed(error)                         # once, when the job gives up
#     def ai_cancelled?                            # true when the user cancelled
#     def self.from_shadow_job(ids:, family_id:)   # with ai_shadow_generation: optional, for Ai::ShadowJob
#     def ai_shadow_generation                     # these ids as they are now
#   end
module Ai::Requester
  extend ActiveSupport::Concern

  class_methods do
    def ai_feature(key = nil)
      return @ai_feature if key.nil?

      @ai_feature = key.to_sym
    end
  end

  def ai_cancelled? = false

  def ai_finished(_count) = nil

  def ai_failed(_error) = nil

  # The correlation id the job's calls carry.
  def ai_correlation_id = nil
end
