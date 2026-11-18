# frozen_string_literal: true

require "base64"
require "json"
require "securerandom"

module BaileysRec
  module Builders
    # AI Rich Response Builder (`AIRich` / `Rich`) mirroring `baileys-rec`'s rich message engine.
    class AIRich < BaseBuilder
      HIGHLIGHT_TYPES = {
        default: 0,
        keyword: 1,
        string: 2,
        number: 3,
        method: 4,
        comment: 5
      }.freeze

      KEYWORDS = %w[
        def class module end if elsif else unless case when while until for do begin rescue ensure
        return yield self super true false nil require require_relative include extend attr_reader
        attr_accessor attr_writer const let var function async await import export from return
        try catch throw new switch break continue typeof interface type enum
      ].freeze

      class << self
        def extract_ie(text, hyperlink: true, citation: true, latex: true)
          return { text: text.to_s, ie: [], inline_entities: [] } unless text.is_a?(String)

          entities = []
          ie_list = []
          h_idx = 0
          c_idx = 0
          l_idx = 0

          processed = text.gsub(/\[([^\[\]]*)\](?:\(([^()]+)\)|<([^<>]+)>)/) do |match|
            raw = Regexp.last_match(1).to_s.strip
            paren_url = Regexp.last_match(2)
            angle_url = Regexp.last_match(3)

            if angle_url
              next match unless latex

              url = angle_url.strip
              expr, w, h = raw.split("|", 3)
              key = "LATEX_#{l_idx}"
              l_idx += 1
              entity = {
                key: key,
                metadata: {
                  latex_expression: expr.to_s,
                  latex_image: { url: url, width: (w || 100).to_i, height: (h || 100).to_i },
                  __typename: "GenAILatexItem"
                }
              }
              entities << entity
              ie_list << { type: "latex", ie: entity }
              "{{#{key}}}#{expr.to_s.empty? ? 'image' : expr}{{/#{key}}}"
            else
              url = paren_url.to_s.strip
              if raw.empty?
                next match unless citation

                c_idx += 1
                key = "CITATION_#{c_idx - 1}"
                entity = {
                  key: key,
                  metadata: {
                    reference_id: c_idx,
                    reference_url: url,
                    reference_title: url,
                    reference_display_name: url,
                    sources: [],
                    __typename: "GenAISearchCitationItem"
                  }
                }
                entities << entity
                ie_list << { type: "citation", ie: entity }
                "{{#{key}}}#{url}{{/#{key}}}"
              else
                next match unless hyperlink

                trusted = !url.start_with?("!")
                clean_url = trusted ? url : url[1..]
                key = "HYPERLINK_#{h_idx}"
                h_idx += 1
                entity = {
                  key: key,
                  metadata: {
                    display_name: raw,
                    is_trusted: trusted,
                    url: clean_url,
                    __typename: "GenAIInlineLinkItem"
                  }
                }
                entities << entity
                ie_list << { type: "hyperlink", ie: entity }
                "{{#{key}}}#{clean_url}{{/#{key}}}"
              end
            end
          end

          { text: processed, ie: ie_list, inline_entities: entities }
        end

        def tokenize_code(code_str, _language = "ruby")
          tokenize_code_v2(code_str)[:code_block]
        end

        def tokenize_code_v2(code_str, _language = "ruby")
          scanner = code_str.to_s.scan(/#[^\n]*|\/\/[^\n]*|"[^"\n]*"|'[^'\n]*'|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b|[^\w\s]+|\s+/)
          code_block = []
          unified = []

          scanner.each do |token|
            if token.start_with?("#", "//")
              ht = HIGHLIGHT_TYPES[:comment]
              ut = "COMMENT"
            elsif token.start_with?('"', "'")
              ht = HIGHLIGHT_TYPES[:string]
              ut = "STRING"
            elsif token.match?(/\A\d+(?:\.\d+)?\z/)
              ht = HIGHLIGHT_TYPES[:number]
              ut = "NUMBER"
            elsif KEYWORDS.include?(token)
              ht = HIGHLIGHT_TYPES[:keyword]
              ut = "KEYWORD"
            else
              ht = HIGHLIGHT_TYPES[:default]
              ut = "DEFAULT"
            end

            code_block << { highlightType: ht, codeContent: token }
            unified << { text: token, type: ut }
          end

          { code_block: code_block, unified_code_block: unified }
        end

        def to_table_metadata_v2(rows_input)
          arr = Array(rows_input)
          return { title: "", rows: [], unified_rows: [] } if arr.empty?

          title = arr.first.is_a?(String) && !arr.first.include?("|") ? arr.first : ""
          data_rows = title.empty? ? arr : arr[1..]

          parsed_rows = []
          data_rows.each_with_index do |entry, idx|
            if entry.is_a?(String)
              entry.split(";;").each_with_index do |sub, s_idx|
                cells = sub.split("|").map(&:strip)
                is_heading = idx.zero? && s_idx.zero?
                parsed_rows << { items: cells, isHeading: is_heading }
              end
            elsif entry.is_a?(Array)
              parsed_rows << { items: entry.map(&:to_s), isHeading: idx.zero? }
            end
          end

          unified_rows = parsed_rows.map do |r|
            {
              is_heading: r[:isHeading],
              cells: r[:items].map { |cell| { text: cell } }
            }
          end

          { title: title, rows: parsed_rows, unified_rows: unified_rows }
        end
      end

      def initialize(client = nil)
        super()
        @client = client
        @submessages = []
        @sections = []
      end

      def add_text(text, hyperlink: true, citation: true, latex: true)
        raise TypeError, "Text must be a String" unless text.is_a?(String)

        extracted = self.class.extract_ie(text, hyperlink: hyperlink, citation: citation, latex: latex)
        @submessages << { messageType: 2, messageText: extracted[:text] }
        primitive = { text: extracted[:text], __typename: "GenAIMarkdownTextUXPrimitive" }
        primitive[:inline_entities] = extracted[:inline_entities] unless extracted[:inline_entities].empty?
        @sections << { view_model: { primitive: primitive, __typename: "GenAISingleLayoutViewModel" } }
        self
      end

      def add_code(language, code)
        meta = self.class.tokenize_code_v2(code, language)
        @submessages << {
          messageType: 5,
          codeMetadata: { codeLanguage: language.to_s, codeBlocks: meta[:code_block] }
        }
        @sections << {
          view_model: {
            primitive: {
              language: language.to_s,
              code_blocks: meta[:unified_code_block],
              __typename: "GenAICodeUXPrimitive"
            },
            __typename: "GenAISingleLayoutViewModel"
          }
        }
        self
      end

      def add_table(table_data)
        meta = self.class.to_table_metadata_v2(table_data)
        @submessages << {
          messageType: 4,
          tableMetadata: { title: meta[:title], rows: meta[:rows] }
        }
        @sections << {
          view_model: {
            primitive: {
              title: meta[:title],
              rows: meta[:unified_rows],
              __typename: "GenAITableUXPrimitive"
            },
            __typename: "GenAISingleLayoutViewModel"
          }
        }
        self
      end

      def add_image(url)
        urls = Array(url)
        if urls.size == 1
          @submessages << { messageType: 3, imageUrl: urls.first.to_s }
        else
          @submessages << { messageType: 1, imageUrls: urls.map(&:to_s) }
        end
        self
      end

      def add_source(sources = [])
        @sections << {
          view_model: {
            primitive: {
              sources: Array(sources),
              __typename: "GenAISearchResultPrimitive"
            },
            __typename: "GenAISingleLayoutViewModel"
          }
        }
        self
      end

      def add_tip(text)
        add_text("> #{text}")
      end

      def add_suggest(suggestions)
        @sections << {
          view_model: {
            primitive: {
              suggestions: Array(suggestions).map(&:to_s),
              __typename: "GenAISuggestedPromptPrimitive"
            },
            __typename: "GenAISingleLayoutViewModel"
          }
        }
        self
      end

      def build(jid = nil, _options = {})
        unified_json = JSON.generate({ response_id: SecureRandom.uuid, sections: @sections })
        payload = @_extra_payload.merge(
          botForwardedMessage: {
            message: {
              richResponseMessage: {
                messageType: 1,
                submessages: @submessages,
                unifiedResponse: { data: Base64.strict_encode64(unified_json) },
                contextInfo: @_context_info || {}
              }
            }
          }
        )
        jid ? { jid: Utils::Jid.to_jid(jid), message: payload } : payload
      end

      def send(jid, options = {})
        raise ConfigurationError, "Socket client is required to send message" unless @client

        @client.send_message(jid, build(nil, options), options)
      end
    end

    Rich = AIRich
  end
end
