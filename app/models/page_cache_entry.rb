# One page kept by PageCache: where it is in Rails.cache, how big it is and
# when it was last served, so the cache can be held under its size limit.
class PageCacheEntry < ApplicationRecord
  belongs_to :family
end
