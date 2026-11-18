# frozen_string_literal: true

require "json"
require "securerandom"

module BaileysRec
  module Utils
    module CloudApi
      module_function

      # Generates an audio waveform byte array (0..100) for WhatsApp PTT voice notes.
      def generate_waveform(samples = 64, min: 5, max: 95, variance: 0.35)
        Array.new(samples) do |i|
          normalized = Math.sin((i.to_f / samples) * Math::PI)
          noise = (rand - 0.5) * variance
          amp = ((normalized + noise) * (max - min) + min).round
          amp.clamp(min, max)
        end
      end

      # Converts a Meta WhatsApp Cloud API payload into Baileys-compatible content hash.
      def from_cloud_api_message(payload)
        raise ValidationError, "Invalid Meta Cloud API payload: must be a Hash" unless payload.is_a?(Hash)

        data = deep_symbolize(payload)
        type = (data[:type] || (data[:interactive] ? "interactive" : "text")).to_s

        if type == "text"
          text_obj = data[:text]
          body = text_obj.is_a?(Hash) ? text_obj[:body].to_s : text_obj.to_s
          return { text: body }
        end

        if type == "image" && data[:image].is_a?(Hash)
          return {
            image: { url: data[:image][:link] || data[:image][:url] },
            caption: data[:image][:caption]
          }.compact
        end

        if type == "video" && data[:video].is_a?(Hash)
          return {
            video: { url: data[:video][:link] || data[:video][:url] },
            caption: data[:video][:caption]
          }.compact
        end

        if type == "audio" && data[:audio].is_a?(Hash)
          return {
            audio: { url: data[:audio][:link] || data[:audio][:url] },
            ptt: data[:audio][:ptt] || false
          }
        end

        if type == "document" && data[:document].is_a?(Hash)
          return {
            document: { url: data[:document][:link] || data[:document][:url] },
            fileName: data[:document][:filename],
            caption: data[:document][:caption]
          }.compact
        end

        if type == "location" && data[:location].is_a?(Hash)
          loc = data[:location]
          return {
            location: {
              degreesLatitude: loc[:latitude],
              degreesLongitude: loc[:longitude],
              name: loc[:name],
              address: loc[:address]
            }.compact
          }
        end

        if type == "contacts" && data[:contacts].is_a?(Array)
          first = data[:contacts].first || {}
          return {
            contacts: {
              displayName: first.dig(:name, :formatted_name) || "Contact",
              contacts: data[:contacts]
            }
          }
        end

        return convert_interactive_payload(data[:interactive] || {}) if type == "interactive"
        return convert_template_payload(data[:template]) if type == "template" && data[:template].is_a?(Hash)

        { text: JSON.generate(data) }
      end

      # Converts Baileys content back into official Meta Cloud API v21.0 JSON format.
      def to_cloud_api_message(content, recipient_phone = "")
        clean_to = Jid.sanitize_whatsapp_number(recipient_phone)
        base = {
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: clean_to
        }

        return base.merge(type: "text", text: { body: content.to_s }) unless content.is_a?(Hash)

        c = deep_symbolize(content)

        if c[:image]
          return base.merge(
            type: "image",
            image: { link: extract_media_url(c[:image]), caption: c[:caption] }.compact
          )
        end

        if c[:video]
          return base.merge(
            type: "video",
            video: { link: extract_media_url(c[:video]), caption: c[:caption] }.compact
          )
        end

        if c[:audio]
          return base.merge(
            type: "audio",
            audio: { link: extract_media_url(c[:audio]) }
          )
        end

        if c[:document]
          return base.merge(
            type: "document",
            document: {
              link: extract_media_url(c[:document]),
              filename: c[:fileName] || c[:filename],
              caption: c[:caption]
            }.compact
          )
        end

        if c[:location]
          loc = c[:location]
          return base.merge(
            type: "location",
            location: {
              latitude: loc[:degreesLatitude] || loc[:latitude],
              longitude: loc[:degreesLongitude] || loc[:longitude],
              name: loc[:name],
              address: loc[:address]
            }.compact
          )
        end

        if c[:cards].is_a?(Array)
          return base.merge(
            type: "interactive",
            interactive: {
              type: "carousel",
              body: { text: c[:text] || c[:caption] || "" },
              footer: c[:footer] ? { text: c[:footer] } : nil,
              action: {
                cards: c[:cards].each_with_index.map do |card, idx|
                  {
                    card_index: idx,
                    header: if card[:image]
                              { type: "image", image: { link: extract_media_url(card[:image]) } }
                            elsif card[:title]
                              { type: "text", text: card[:title] }
                            end,
                    body: { text: card[:text] || card[:caption] || card[:body] || "" },
                    action: {
                      buttons: Array(card[:nativeFlow] || card[:buttons]).each_with_index.map do |b, b_idx|
                        {
                          type: "reply",
                          reply: {
                            id: b[:id] || "btn_#{idx}_#{b_idx}",
                            title: b[:text] || b[:buttonText] || "Select"
                          }
                        }
                      end
                    }
                  }.compact
                end
              }
            }.compact
          )
        end

        if c[:nativeFlow] || c[:buttons]
          buttons = Array(c[:nativeFlow] || c[:buttons])
          first = buttons.first || {}
          header_obj = c[:title] ? { type: "text", text: c[:title] } : nil
          footer_obj = c[:footer] ? { text: c[:footer] } : nil

          if first[:sections]
            return base.merge(
              type: "interactive",
              interactive: {
                type: "list",
                header: header_obj,
                body: { text: c[:text] || c[:caption] || "Please select an option:" },
                footer: footer_obj,
                action: {
                  button: first[:text] || "Select",
                  sections: first[:sections]
                }
              }.compact
            )
          end

          if first[:url]
            return base.merge(
              type: "interactive",
              interactive: {
                type: "cta_url",
                header: header_obj,
                body: { text: c[:text] || c[:caption] || "" },
                footer: footer_obj,
                action: {
                  name: "cta_url",
                  parameters: {
                    display_text: first[:text] || "Visit",
                    url: first[:url]
                  }
                }
              }.compact
            )
          end

          if buttons.length > 3
            return base.merge(
              type: "interactive",
              interactive: {
                type: "list",
                header: header_obj,
                body: { text: c[:text] || c[:caption] || "Options:" },
                footer: footer_obj,
                action: {
                  button: "Select Option",
                  sections: [
                    {
                      title: "Available Options",
                      rows: buttons.each_with_index.map do |b, i|
                        { id: b[:id] || "opt_#{i}", title: (b[:text] || "Option #{i + 1}")[0, 24] }
                      end
                    }
                  ]
                }
              }.compact
            )
          end

          return base.merge(
            type: "interactive",
            interactive: {
              type: "button",
              header: header_obj,
              body: { text: c[:text] || c[:caption] || "" },
              footer: footer_obj,
              action: {
                buttons: buttons.each_with_index.map do |b, i|
                  {
                    type: "reply",
                    reply: {
                      id: b[:id] || "btn_#{i}",
                      title: (b[:text] || "Option #{i + 1}")[0, 20]
                    }
                  }
                end
              }
            }.compact
          )
        end

        base.merge(type: "text", text: { body: c[:text].to_s })
      end

      def diagnose_meta_cloud_api_error(error)
        err = error.is_a?(Hash) ? deep_symbolize(error) : {}
        inner = err[:error].is_a?(Hash) ? err[:error] : err
        code = inner[:code].to_i
        subcode = inner[:error_subcode]
        message = (inner[:message] || error.to_s).to_s

        if code == 131_047 || message.include?("24 hours") || message.include?("re-engagement")
          return {
            code: code,
            title: "Customer Service Window Expired (24h Rule)",
            explanation: "More than 24 hours elapsed since the recipient last messaged your business number.",
            suggestion: "Send an approved Meta Template Message (type: 'template') to re-open the 24h window."
          }
        end

        if code == 131_030 || message.include?("allowed list")
          return {
            code: code,
            title: "Recipient Not In Sandbox Whitelist",
            explanation: "Sandbox test phone numbers only deliver to numbers in the Meta Allowed Phone Numbers list.",
            suggestion: "Add the recipient phone number in Meta App Dashboard -> WhatsApp -> API Setup."
          }
        end

        if code == 190 || subcode == 463 || message.include?("Session has expired") || message.include?("access token")
          return {
            code: code,
            title: "Meta Access Token Expired or Invalid",
            explanation: "Temporary Meta Graph API tokens expire after 24 hours or the token is invalid.",
            suggestion: "Generate a permanent System User Token in Meta Business Manager."
          }
        end

        if code == 100 || message.include?("Invalid parameter")
          return {
            code: code,
            title: "Invalid Request Parameter",
            explanation: "Meta Graph API rejected the payload (bad phone digits, >3 reply buttons, or title >20 chars).",
            suggestion: "Verify E.164 digits without '+', keep reply buttons <= 3, and titles <= 20 chars."
          }
        end

        if code == 131_026 || message.include?("undeliverable")
          return {
            code: code,
            title: "Message Undeliverable",
            explanation: "Destination number is not registered on WhatsApp or blocked this business account.",
            suggestion: "Verify the destination WhatsApp number is active."
          }
        end

        {
          code: code,
          title: "Meta Cloud API Error (#{code.zero? ? 'Unknown' : code})",
          explanation: message,
          suggestion: "Check the Meta Cloud API payload and credentials."
        }
      end

      # Universal incoming WAMessage serializer for messages.upsert events.
      def serialize_message(msg)
        return nil unless msg.is_a?(Hash)

        m = deep_symbolize(msg)
        key = m[:key] || {}
        from = key[:remoteJid].to_s
        from_alt = key[:remoteJidAlt].to_s
        is_group = Jid.group_jid?(from)
        is_newsletter = Jid.newsletter_jid?(from)
        sender = is_group ? (key[:participant] || from) : from
        sender_alt = (is_group ? key[:participantAlt] : key[:remoteJidAlt]).to_s

        raw = m[:message] || {}
        normalized = raw.dig(:ephemeralMessage, :message) ||
                     raw.dig(:viewOnceMessage, :message) ||
                     raw.dig(:viewOnceMessageV2, :message) ||
                     raw.dig(:viewOnceMessageV2Extension, :message) ||
                     raw.dig(:documentWithCaptionMessage, :message) ||
                     raw

        msg_type = normalized.keys.first.to_s
        body = raw[:conversation] ||
               normalized[:conversation] ||
               normalized.dig(:extendedTextMessage, :text) ||
               normalized.dig(:imageMessage, :caption) ||
               normalized.dig(:videoMessage, :caption) ||
               normalized.dig(:documentMessage, :caption) ||
               ""

        interactive = extract_interactive_response(normalized)
        body = interactive[:text] if body.empty? && interactive && interactive[:text]

        {
          id: key[:id].to_s,
          from: from,
          from_alt: from_alt,
          sender: sender,
          sender_alt: sender_alt,
          from_me: !key[:fromMe].nil? && key[:fromMe] != false,
          is_group: is_group,
          is_newsletter: is_newsletter,
          push_name: m[:pushName].to_s,
          timestamp: m[:messageTimestamp].to_i,
          type: msg_type,
          body: body.to_s,
          interactive: interactive,
          raw: m
        }
      end

      def deep_symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = deep_symbolize(v) }
        when Array
          obj.map { |v| deep_symbolize(v) }
        else
          obj
        end
      end

      def extract_media_url(media)
        media.is_a?(String) ? media : (media[:url] || media[:link])
      end

      def convert_interactive_payload(interactive)
        itype = interactive[:type].to_s
        body_text = interactive.dig(:body, :text).to_s
        footer_text = interactive.dig(:footer, :text)
        header = interactive[:header]

        result = { text: body_text }
        result[:footer] = footer_text if footer_text

        if header.is_a?(Hash)
          case header[:type].to_s
          when "text"
            result[:title] = header[:text] if header[:text]
          when "image"
            url = header.dig(:image, :link) || header.dig(:image, :url)
            if url
              result.delete(:text)
              result[:image] = { url: url }
              result[:caption] = body_text
            end
          when "video"
            url = header.dig(:video, :link) || header.dig(:video, :url)
            if url
              result.delete(:text)
              result[:video] = { url: url }
              result[:caption] = body_text
            end
          when "document"
            url = header.dig(:document, :link) || header.dig(:document, :url)
            if url
              result.delete(:text)
              result[:document] = { url: url }
              result[:fileName] = header.dig(:document, :filename)
              result[:caption] = body_text
            end
          end
        end

        action = interactive[:action] || {}

        case itype
        when "button"
          result[:nativeFlow] = Array(action[:buttons]).map do |btn|
            reply = btn[:reply] || {}
            { id: reply[:id] || "btn_#{SecureRandom.hex(4)}", text: reply[:title] || "Button" }
          end
        when "list"
          result[:nativeFlow] = [
            {
              text: action[:button] || "Select Option",
              sections: Array(action[:sections]).map do |sec|
                {
                  title: sec[:title].to_s,
                  rows: Array(sec[:rows]).map do |row|
                    { id: row[:id], title: row[:title], description: row[:description] }.compact
                  end
                }
              end
            }
          ]
        when "cta_url"
          params = action[:parameters] || {}
          result[:nativeFlow] = [
            { text: params[:display_text] || "Visit Website", url: params[:url] || "#" }
          ]
        when "flow"
          params = action[:parameters] || {}
          result[:nativeFlow] = [{ name: "flow", paramsJson: JSON.generate(params) }]
        when "location_request_message"
          result[:nativeFlow] = [{ name: "send_location", paramsJson: "{}" }]
        when "product"
          result[:nativeFlow] = [
            {
              name: "single_product",
              product_retailer_id: action[:product_retailer_id],
              catalog_id: action[:catalog_id],
              text: action[:button] || "View Product"
            }
          ]
        when "product_list"
          result[:nativeFlow] = [
            {
              name: "product_list",
              catalog_id: action[:catalog_id],
              sections: action[:sections] || [],
              text: action[:button] || "View Products"
            }
          ]
        when "catalog_message"
          result[:nativeFlow] = [
            {
              name: "open_catalog",
              catalog_id: action[:catalog_id],
              business_owner_jid: action[:business_owner_jid],
              text: action[:button] || "View Catalog"
            }
          ]
        when "carousel"
          result[:cards] = Array(action[:cards]).each_with_index.map do |card, idx|
            c_header = card[:header] || {}
            c_body = card[:body] || {}
            c_buttons = card[:buttons] || card.dig(:action, :buttons) || []
            img_url = c_header.dig(:image, :link) || c_header.dig(:image, :url)

            card_hash = {
              title: c_header[:text] || "Card #{idx + 1}",
              text: c_body[:text] || "",
              buttons: c_buttons.each_with_index.map do |b, b_idx|
                reply = b[:reply] || {}
                { id: b[:id] || reply[:id] || "card_#{idx}_btn_#{b_idx}", text: b[:text] || reply[:title] || "Select" }
              end
            }
            card_hash[:image] = { url: img_url } if img_url
            card_hash
          end
        end

        result
      end

      def convert_template_payload(tmpl)
        components = Array(tmpl[:components])
        header_comp = components.find { |c| c[:type].to_s == "header" }
        body_comp = components.find { |c| c[:type].to_s == "body" }
        footer_comp = components.find { |c| c[:type].to_s == "footer" }
        button_comps = components.select { |c| c[:type].to_s == "button" }
        carousel_comp = components.find { |c| c[:type].to_s == "carousel" }

        body_text = Array(body_comp&.dig(:parameters)).map { |p| p[:text] }.compact.join(" ")
        body_text = tmpl[:name].to_s if body_text.empty?

        if carousel_comp && carousel_comp[:cards].is_a?(Array)
          cards = carousel_comp[:cards].each_with_index.map do |card, c_idx|
            c_comps = Array(card[:components])
            ch = c_comps.find { |c| c[:type].to_s == "header" }
            cb = c_comps.find { |c| c[:type].to_s == "body" }
            c_btns = c_comps.select { |c| c[:type].to_s == "button" }
            img_p = Array(ch&.dig(:parameters)).find { |p| p[:type].to_s == "image" }
            txt_p = Array(ch&.dig(:parameters)).find { |p| p[:type].to_s == "text" }

            card_obj = {
              title: txt_p&.dig(:text) || "Card #{c_idx + 1}",
              text: Array(cb&.dig(:parameters)).map { |p| p[:text] }.compact.join(" "),
              buttons: c_btns.each_with_index.map do |b, b_idx|
                param = Array(b[:parameters]).first || {}
                {
                  id: param[:payload] || "card_#{c_idx}_btn_#{b_idx}",
                  text: param[:text] || b[:sub_type] || "Select"
                }
              end
            }
            if img_p
              url = img_p.dig(:image, :link) || img_p.dig(:image, :url)
              card_obj[:image] = { url: url } if url
            end
            card_obj
          end

          return { text: body_text, cards: cards }
        end

        result = { text: body_text }
        footer_text = footer_comp&.dig(:parameters, 0, :text)
        result[:footer] = footer_text if footer_text

        if header_comp
          param = Array(header_comp[:parameters]).first || {}
          case param[:type].to_s
          when "text"
            result[:title] = param[:text] if param[:text]
          when "image"
            url = param.dig(:image, :link) || param.dig(:image, :url)
            if url
              result.delete(:text)
              result[:image] = { url: url }
              result[:caption] = body_text
            end
          when "video"
            url = param.dig(:video, :link) || param.dig(:video, :url)
            if url
              result.delete(:text)
              result[:video] = { url: url }
              result[:caption] = body_text
            end
          when "document"
            url = param.dig(:document, :link) || param.dig(:document, :url)
            if url
              result.delete(:text)
              result[:document] = { url: url }
              result[:caption] = body_text
            end
          end
        end

        unless button_comps.empty?
          result[:nativeFlow] = button_comps.each_with_index.map do |b, idx|
            sub_type = b[:sub_type].to_s
            param = Array(b[:parameters]).first || {}
            if sub_type == "url"
              url_val = param[:text] ? "https://#{param[:text]}" : (param[:url] || "#")
              { url: url_val, text: b[:text] || "Visit Website" }
            elsif sub_type == "copy_code" || param[:type].to_s == "coupon_code"
              { copy: param[:coupon_code] || param[:text] || param[:code] || "", text: b[:text] || "Copy Code" }
            elsif sub_type == "flow"
              { name: "flow", paramsJson: JSON.generate(param.dig(:action, :parameters) || param) }
            else
              { id: param[:payload] || "btn_#{idx}", text: param[:text] || b[:text] || "Option #{idx + 1}" }
            end
          end
        end

        result
      end

      def extract_interactive_response(normalized)
        if (resp = normalized[:interactiveResponseMessage])
          nf = resp[:nativeFlowResponseMessage] || {}
          params = begin
            JSON.parse(nf[:paramsJson].to_s)
          rescue JSON::ParserError
            {}
          end
          return {
            kind: :native_flow,
            name: nf[:name],
            id: params["id"] || params["flow_token"] || nf[:name],
            text: resp.dig(:body, :text) || params["id"] || "",
            params: params
          }
        end

        if (btn = normalized[:buttonsResponseMessage])
          return {
            kind: :button_reply,
            id: btn[:selectedButtonId],
            text: btn[:selectedDisplayText]
          }
        end

        if (list = normalized[:listResponseMessage])
          return {
            kind: :list_reply,
            id: list.dig(:singleSelectReply, :selectedRowId),
            text: list[:title]
          }
        end

        if (tmpl = normalized[:templateButtonReplyMessage])
          return {
            kind: :template_reply,
            id: tmpl[:selectedId],
            text: tmpl[:selectedDisplayText]
          }
        end

        nil
      end
    end
  end
end
