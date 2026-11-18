# frozen_string_literal: true

require_relative "test_helper"

class AiRichTest < Minitest::Test
  def test_tokenize_code_v2
    v2 = WhatsappWebRuby::AIRich.tokenize_code_v2("def calc(x)\n  return x * 2\nend", "ruby")
    assert v2[:unified_code_block].any? { |b| b[:text] == "def" && b[:type] == "KEYWORD" }
    assert v2[:unified_code_block].any? { |b| b[:text] == "return" && b[:type] == "KEYWORD" }
    assert v2[:unified_code_block].any? { |b| b[:text] == "2" && b[:type] == "NUMBER" }
  end

  def test_extract_ie_hyperlinks_citations_and_latex
    input = "Read [Docs](https://baileys.wiki) and [Evil](!https://evil.com) plus [](https://src.com) and [E=mc^2|120|60]<https://latex.example/e.png>"
    res = WhatsappWebRuby::AIRich.extract_ie(input)

    assert_includes res[:text], "{{HYPERLINK_0}}"
    assert_includes res[:text], "{{HYPERLINK_1}}"
    assert_includes res[:text], "{{CITATION_0}}"
    assert_includes res[:text], "{{LATEX_0}}"
    assert_equal 4, res[:inline_entities].size
    assert_equal true, res[:inline_entities][0][:metadata][:is_trusted]
    assert_equal false, res[:inline_entities][1][:metadata][:is_trusted]
  end

  def test_to_table_metadata_v2
    data = [
      "Leaderboard",
      "Rank | Player | Score",
      "#1 | Alice | 9950;;#2 | Bob | 8420"
    ]
    table = WhatsappWebRuby::AIRich.to_table_metadata_v2(data)
    assert_equal "Leaderboard", table[:title]
    assert_equal 3, table[:rows].size
    assert_equal true, table[:rows][0][:isHeading]
    assert_equal "Alice", table[:rows][1][:items][1]
    assert_equal "Bob", table[:rows][2][:items][1]
  end

  def test_newsletter_helper
    assert_equal true, WhatsappWebRuby::NewsletterHelper.newsletter_jid?("120363123@newsletter")
    msg = WhatsappWebRuby::NewsletterHelper.build_newsletter_message("Hello channel", is_forwarded: true)
    assert_equal "Hello channel", msg[:text]
    assert_equal true, msg[:contextInfo][:isForwarded]
  end
end
