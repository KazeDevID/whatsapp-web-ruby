# frozen_string_literal: true

module BaileysRec
  module Builders
    class BaseBuilder
      attr_reader :_title, :_subtitle, :_body, :_footer, :_context_info, :_extra_payload

      def initialize
        @_title = ""
        @_subtitle = ""
        @_body = ""
        @_footer = ""
        @_context_info = nil
        @_extra_payload = {}
      end

      def set_title(title)
        @_title = title.to_s
        self
      end
      alias title set_title

      def set_subtitle(subtitle)
        @_subtitle = subtitle.to_s
        self
      end
      alias subtitle set_subtitle

      def set_body(body)
        @_body = body.to_s
        self
      end
      alias text set_body

      def set_footer(footer)
        @_footer = footer.to_s
        self
      end
      alias footer set_footer

      def set_context_info(obj)
        @_context_info = obj
        self
      end

      def add_payload(obj)
        @_extra_payload.merge!(obj) if obj.is_a?(Hash)
        self
      end
    end
  end
end
