# frozen_string_literal: true

require "json"
require "securerandom"

module WhatsappWebRuby
  module Builders
    # Fluent NativeFlow Interactive Button Builder mirroring `WhatsappWebRuby::Button`.
    class Button < BaseBuilder
      attr_reader :buttons, :media_type, :media_data

      def initialize(client = nil)
        super()
        @client = client
        @buttons = []
        @media_type = nil
        @media_data = nil
        @media_options = {}
        @params = {}
      end

      def set_image(source, options = {})
        @media_type = :image
        @media_data = normalize_media_source(source)
        @media_options = options
        self
      end

      def set_video(source, options = {})
        @media_type = :video
        @media_data = normalize_media_source(source)
        @media_options = options
        self
      end

      def set_document(source, options = {})
        @media_type = :document
        @media_data = normalize_media_source(source)
        @media_options = options
        self
      end

      def set_media(obj)
        if obj.is_a?(Hash)
          @media_type = obj[:type]&.to_sym || :image
          @media_data = obj[:url] ? { url: obj[:url] } : obj
        end
        self
      end

      def clear_buttons
        @buttons.clear
        self
      end

      def set_params(obj)
        @params.merge!(obj) if obj.is_a?(Hash)
        self
      end

      def add_button(name, params)
        json_str = params.is_a?(String) ? params : JSON.generate(params)
        @buttons << { name: name.to_s, buttonParamsJson: json_str }
        self
      end

      # Quick Reply Button
      def add_reply(display_text = "Reply", id = SecureRandom.uuid, _options = {})
        add_button("quick_reply", { display_text: display_text.to_s, id: id.to_s })
      end

      # External URL CTA Button
      def add_url(display_text = "Open Link", url = "https://example.com", webview_interaction = false, _options = {})
        add_button("cta_url", {
          display_text: display_text.to_s,
          url: url.to_s,
          merchant_url: url.to_s,
          webview_interaction: !!webview_interaction
        })
      end

      # Copy to Clipboard Button
      def add_copy(display_text = "Copy Code", copy_code = "", _options = {})
        add_button("cta_copy", { display_text: display_text.to_s, copy_code: copy_code.to_s })
      end

      # OTP Verification Code Copy Button (v1.6.0 parity)
      def add_otp(code, display_text = "Copy Code", _options = {})
        add_button("cta_copy", {
          display_text: display_text.to_s,
          id: "otp_#{code}",
          copy_code: code.to_s
        })
      end

      # Direct Phone Call Button
      def add_call(display_text = "Call Us", phone = "", _options = {})
        add_button("cta_call", { display_text: display_text.to_s, phone_number: phone.to_s })
      end

      # Single Select List Menu (call make_section + make_row after)
      def add_selection(title = "Select Option", _options = {})
        add_button("single_select", { title: title.to_s, sections: [] })
      end

      def make_section(title = "", highlight_label = nil)
        last = @buttons.reverse.find { |b| b[:name] == "single_select" }
        raise ValidationError, "Call add_selection before make_section" unless last

        parsed = JSON.parse(last[:buttonParamsJson])
        sec = { title: title.to_s, rows: [] }
        sec[:highlight_label] = highlight_label.to_s if highlight_label
        parsed["sections"] << sec
        last[:buttonParamsJson] = JSON.generate(parsed)
        self
      end

      def make_row(header = "", title = "", description = "", id = SecureRandom.uuid)
        last = @buttons.reverse.find { |b| b[:name] == "single_select" }
        raise ValidationError, "Call add_selection and make_section before make_row" unless last

        parsed = JSON.parse(last[:buttonParamsJson])
        parsed["sections"] << { title: "", rows: [] } if parsed["sections"].empty?
        parsed["sections"].last["rows"] << {
          header: header.to_s,
          title: title.to_s,
          description: description.to_s,
          id: id.to_s
        }
        last[:buttonParamsJson] = JSON.generate(parsed)
        self
      end

      def add_location_request(display_text = "Share Location", _options = {})
        add_button("send_location", { display_text: display_text.to_s })
      end

      def add_flow(flow_id, options = {})
        display_text = options[:display_text] || options[:text] || "Open Form"
        flow_token = options[:flow_token] || options[:token] || SecureRandom.hex(6)
        flow_action = options[:flow_action] || options[:action] || "navigate"
        payload = options[:flow_action_payload] || options[:payload] || { screen: "FIRST_SCREEN" }

        add_button("flow", {
          flow_message_version: "3",
          flow_token: flow_token.to_s,
          flow_id: flow_id.to_s,
          flow_cta: display_text.to_s,
          flow_action: flow_action.to_s,
          flow_action_payload: payload
        })
      end

      def add_address_request(display_text = "Provide Address", options = {})
        add_button("address_message", {
          display_text: display_text.to_s,
          values: options[:values] || {}
        })
      end

      def add_review_order(order_data = {}, _options = {})
        add_button("review_order", order_data)
      end

      def add_order_status(reference_id, status = "completed", description = "", display_text = "Order Status", _options = {})
        add_button("order_status", {
          reference_id: reference_id.to_s,
          order: { status: status.to_s, description: description.to_s },
          display_text: display_text.to_s
        })
      end

      def add_reminder(display_text = "Set Reminder", timestamp = nil, _options = {})
        add_button("cta_reminder", {
          display_text: display_text.to_s,
          id: SecureRandom.hex(4),
          reminder_timestamp: timestamp || (Time.now.to_i + 3600)
        })
      end

      def add_cancel_reminder(display_text = "Cancel Reminder", reminder_id = "1", _options = {})
        add_button("cta_cancel_reminder", {
          display_text: display_text.to_s,
          id: reminder_id.to_s
        })
      end

      def add_catalog(display_text = "View Catalog", business_owner_jid = "", _options = {})
        add_button("open_catalog", {
          display_text: display_text.to_s,
          business_owner_jid: business_owner_jid.to_s
        })
      end

      def add_product(product_retailer_id, catalog_id, display_text = "View Product", _options = {})
        add_button("single_product", {
          product_retailer_id: product_retailer_id.to_s,
          catalog_id: catalog_id.to_s,
          display_text: display_text.to_s
        })
      end

      def add_product_list(catalog_id, sections = [], display_text = "View Products", _options = {})
        add_button("product_list", {
          catalog_id: catalog_id.to_s,
          sections: sections,
          display_text: display_text.to_s
        })
      end

      def add_payment(payment_config = {}, display_text = "Pay Now", _options = {})
        add_button("review_and_pay", payment_config.merge(display_text: display_text.to_s))
      end

      def add_pix_payment(pix_code, amount = 0, merchant_name = "", display_text = "Pay with PIX", _options = {})
        amt_obj = amount.is_a?(Hash) ? amount : { value: amount.to_i, offset: 100 }
        add_button("review_and_pay", {
          paymentType: "pix",
          pixCode: pix_code.to_s,
          amount: amt_obj,
          merchantName: merchant_name.to_s,
          display_text: display_text.to_s
        })
      end

      def add_payment_status(reference_id, status = "success", payment_config = {}, display_text = "Payment Status", _options = {})
        add_button("payment_status_update", {
          referenceId: reference_id.to_s,
          status: status.to_s,
          display_text: display_text.to_s
        }.merge(payment_config))
      end

      def add_call_permission(display_text = "Request Call Permission", _options = {})
        add_button("call_permission_request", { display_text: display_text.to_s })
      end

      def add_webview(url, display_text = "Open Webview", title = nil, _options = {})
        add_button("cta_url", {
          display_text: display_text.to_s,
          url: url.to_s,
          merchant_url: url.to_s,
          webview_interaction: true,
          webview_presentation: "full",
          title: (title || display_text).to_s
        })
      end

      # Serializes this Button into a Carousel Card structure.
      def to_card
        header = {
          title: @_title.empty? ? nil : @_title,
          subtitle: @_subtitle.empty? ? nil : @_subtitle,
          hasMediaAttachment: !@media_data.nil?
        }.compact

        header[@media_type] = @media_data if @media_type && @media_data

        {
          header: header,
          body: { text: @_body.empty? ? " " : @_body },
          footer: @_footer.empty? ? nil : { text: @_footer },
          nativeFlowMessage: {
            messageParamsJson: @params.empty? ? "" : JSON.generate(@params),
            buttons: @buttons.dup,
            messageVersion: 1
          }
        }.compact
      end

      # Builds a complete interactiveMessage / viewOnceMessage payload compatible with baileys-rec.
      def build(jid = nil, _options = {})
        has_header = !@_title.empty? || !@_subtitle.empty? || !@media_data.nil?
        header = if has_header
                   h = {
                     title: @_title.empty? ? nil : @_title,
                     subtitle: @_subtitle.empty? ? nil : @_subtitle,
                     hasMediaAttachment: !@media_data.nil?
                   }.compact
                   h[@media_type] = @media_data if @media_type && @media_data
                   h
                 end

        interactive_msg = {
          header: header,
          body: { text: @_body.empty? ? " " : @_body },
          footer: @_footer.empty? ? nil : { text: @_footer },
          nativeFlowMessage: {
            messageParamsJson: @params.empty? ? "" : JSON.generate(@params),
            buttons: @buttons.dup,
            messageVersion: 1
          },
          contextInfo: @_context_info
        }.compact

        payload = @_extra_payload.merge(
          viewOnceMessage: {
            message: {
              messageContextInfo: {
                deviceListMetadata: {},
                deviceListMetadataVersion: 2
              },
              interactiveMessage: interactive_msg
            }
          }
        )

        jid ? { jid: Utils::Jid.to_jid(jid), message: payload } : payload
      end

      def send(jid, options = {})
        raise ConfigurationError, "Socket client is required to send message" unless @client

        if @client.respond_to?(:send_interactive) && @_extra_payload.empty?
          content = {
            title: @_title.empty? ? nil : @_title,
            subtitle: @_subtitle.empty? ? nil : @_subtitle,
            body: @_body,
            footer: @_footer.empty? ? nil : @_footer,
            buttons: @buttons.dup
          }.compact
          content[@media_type] = @media_data if @media_type && @media_data
          return @client.send_interactive(jid, content, options)
        end

        @client.send_message(jid, build(nil, options), options)
      end

      private

      def normalize_media_source(source)
        return source if source.is_a?(Hash)

        { url: source.to_s }
      end
    end

    # Legacy ButtonsMessage Builder mirroring `ButtonV2`.
    class ButtonV2 < BaseBuilder
      def initialize(client = nil)
        super()
        @client = client
        @buttons = []
        @thumbnail = nil
        @media = nil
      end

      def add_button(display_text = "", button_id = SecureRandom.uuid)
        @buttons << {
          buttonId: button_id.to_s,
          buttonText: { displayText: display_text.to_s },
          type: 1
        }
        self
      end

      def set_thumbnail(path)
        @thumbnail = path
        self
      end

      def set_media(obj)
        @media = obj
        self
      end

      def build(jid = nil, _options = {})
        payload = @_extra_payload.merge(
          buttonsMessage: {
            contentText: @_body,
            footerText: @_footer,
            headerType: 1,
            viewOnce: true,
            contextInfo: @_context_info,
            buttons: @buttons.dup
          }.compact
        )
        jid ? { jid: Utils::Jid.to_jid(jid), message: payload } : payload
      end

      def send(jid, options = {})
        raise ValidationError, "ButtonV2 requires at least one button" if @buttons.empty?
        raise ConfigurationError, "Socket client is required to send message" unless @client

        @client.send_message(jid, build(nil, options), options)
      end
    end
  end
end
