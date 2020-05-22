# frozen_string_literal: true

require 'view/hit_box'
require 'view/part/base'
require 'view/runnable'

module View
  module Part
    class TrackOffboard < Base
      include Runnable

      needs :path
      needs :offboard
      needs :color, default: 'black'

      REGIONS = {
        0 => [21],
        1 => [13],
        2 => [6],
        3 => [2],
        4 => [10],
        5 => [17],
      }.freeze

      def edge
        @edge ||= @path.exits[0]
      end

      def preferred_render_locations
        [
          {
            region_weights: REGIONS[edge],
            x: 0,
            y: 0,
          }
        ]
      end

      def render_part
        rotate = 60 * edge

        props = {
          attrs: {
            transform: "rotate(#{rotate})",
            d: 'M6 75 L 6 85 L -6 85 L -6 75 L 0 48 Z',
            fill: @color,
            stroke: 'none',
            'stroke-linecap': 'butt',
            'stroke-linejoin': 'miter',
            'stroke-width': 6,
          }
        }

        radians = (edge * 60) / 180 * Math::PI
        translate = "translate(#{-Math.sin(radians) * 60}, #{Math.cos(radians) * 60})"

        h(:g, [
          h(:path, props),
          h(HitBox, click: -> { touch_node(@offboard) }, transform: translate),
        ])
      end
    end
  end
end
