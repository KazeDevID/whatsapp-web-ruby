# frozen_string_literal: true

require "json"

module BaileysRec
  module Builders
    # WhatsApp Flows v3.1 Schema & Screen Builder mirroring `BaileysRec::FlowBuilder`.
    class FlowBuilder
      attr_reader :flow_id, :title, :version, :screens

      def initialize(flow_id = "custom_flow", title = "WhatsApp Flow", version: "3.1")
        @flow_id = flow_id.to_s
        @title = title.to_s
        @version = version.to_s
        @screens = []
        @current_screen = nil
      end

      def add_screen(screen_id, title = nil, options = {})
        screen = {
          id: screen_id.to_s,
          title: (title || screen_id).to_s,
          data: options[:data] || {},
          terminal: options.fetch(:terminal, false),
          layout: {
            type: "SingleColumnLayout",
            children: []
          }
        }
        @screens << screen
        @current_screen = screen
        self
      end

      def add_text_input(name, label, options = {})
        ensure_screen!
        @current_screen[:layout][:children] << {
          type: "TextInput",
          name: name.to_s,
          label: label.to_s,
          required: options.fetch(:required, true),
          helper_text: options[:helper_text].to_s,
          input_type: options.fetch(:input_type, "text").to_s
        }
        self
      end

      def add_dropdown(name, label, items = [], options = {})
        ensure_screen!
        @current_screen[:layout][:children] << {
          type: "Dropdown",
          name: name.to_s,
          label: label.to_s,
          required: options.fetch(:required, true),
          data_source: normalize_data_source(items)
        }
        self
      end

      def add_radio_buttons(name, label, items = [], options = {})
        ensure_screen!
        @current_screen[:layout][:children] << {
          type: "RadioButtonsGroup",
          name: name.to_s,
          label: label.to_s,
          required: options.fetch(:required, true),
          data_source: normalize_data_source(items)
        }
        self
      end

      def add_checkbox_group(name, label, items = [], options = {})
        ensure_screen!
        @current_screen[:layout][:children] << {
          type: "CheckboxGroup",
          name: name.to_s,
          label: label.to_s,
          required: options.fetch(:required, false),
          data_source: normalize_data_source(items)
        }
        self
      end

      def add_footer(label = "Continue", action = "navigate", payload = {})
        ensure_screen!
        @current_screen[:layout][:children] << {
          type: "Footer",
          label: label.to_s,
          on_click_action: {
            name: action.to_s,
            payload: payload
          }
        }
        self
      end

      def build_json
        {
          version: @version,
          screens: @screens
        }
      end

      def to_flow_button(display_text = "Open Form", token = "1")
        {
          name: "flow",
          buttonParamsJson: JSON.generate(
            flow_message_version: "3",
            flow_token: token.to_s,
            flow_id: @flow_id,
            flow_cta: display_text.to_s,
            flow_action: "navigate",
            flow_action_payload: {
              screen: @screens.first&.dig(:id) || "FIRST_SCREEN"
            }
          )
        }
      end

      private

      def ensure_screen!
        add_screen("SCREEN_1", @title) unless @current_screen
      end

      def normalize_data_source(items)
        Array(items).map do |item|
          item.is_a?(Hash) ? item : { id: item.to_s, title: item.to_s }
        end
      end
    end
  end
end
