require "pagy/extras/overflow"
require "pagy/extras/array"

Pagy::DEFAULT[:overflow] = :last_page
Pagy::DEFAULT[:size] = 9 # Pagy 9 default is 7; widen the series so more page buttons show
