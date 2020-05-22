# frozen_string_literal: true

require 'view/hit_box'
require 'view/part/base'
require 'view/runnable'

module View
  module Part
    class TownDot < Base
      include Runnable

      needs :color, default: 'black'
      needs :tile
      needs :town

      CENTER_TOWN = [
        {
          region_weights: CENTER,
          x: 0,
          y: 0,
        }
      ].freeze

      OFFSET_TOWNS = [
        {
          region_weights: [13, 14],
          x: -40,
          y: 20,
        },
        {
          region_weights: [9, 10],
          x: 40,
          y: -20,
        },
        {
          region_weights: { [6, 7] => 0.5 },
          x: -40,
          y: -20,
        },
        {
          region_weights: { [16, 17] => 0.5 },
          x: 40,
          y: 20,
        },
      ].freeze

      def preferred_render_locations
        @tile.towns.size > 1 ? OFFSET_TOWNS : CENTER_TOWN
      end

      def render_part
        h(:g, [
          h(:circle, attrs: { transform: translate, fill: @color, r: 10 }),
          h(HitBox, click: -> { touch_node(@town) }, transform: translate),
        ])
      end
    end
  end
end
