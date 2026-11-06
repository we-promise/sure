# The domain side of a generation feature (section 8.1): a domain class that rebuilds itself
# from job arguments, makes the generation and applies the result. Ai::GenerationJob talks only
# to the requester, so it never knows what categorizing or detecting merchants means.
#
#   class Family::AutoCategorizer
#     include Ai::Requester
#     ai_feature :categorize
#
#     def self.from_ai_job(ids:, family_id:, **)   # job arguments are ids, never records
#     def ai_generation                            # the generation for the remaining items, or nil
#     def apply_ai(result)                         # writes through the domain; returns a count
#     def ai_finished(count)                       # once, after the last batch
#     def ai_failed(error)                         # once, when the job gives up
#     def ai_cancelled?                            # true when the user cancelled (PR 3)
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

  # The correlation id the job's calls carry (section 10).
  def ai_correlation_id = nil
end
