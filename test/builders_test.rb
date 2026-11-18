# frozen_string_literal: true

require_relative "test_helper"

class BuildersTest < Minitest::Test
  def test_button_builder_chains_all_native_flow_types
    btn = BaileysRec::Button.new
                            .set_title("Interactive Hub")
                            .set_subtitle("Select an action")
                            .set_body("Welcome to Ruby WhatsApp automation")
                            .set_footer("Powered by baileys_rec")
                            .add_reply("Quick Ping", "btn_ping")
                            .add_url("Docs", "https://github.com/KazeDevID/baileys-rec", true)
                            .add_otp("829104", "Copy OTP")
                            .add_call("Support", "+628123456789")
                            .add_selection("Choose Plan")
                            .make_section("Packages", "Popular")
                            .make_row("Pro", "Monthly Pro", "Full automation", "plan_pro")
                            .add_location_request("Share Location")
                            .add_flow("flow_123", display_text: "Open Survey")
                            .add_pix_payment("pix@merchant.com", 8500, "Shop")
                            .add_order_status("ORD-1", "completed", "Delivered")

    built = btn.build("081234567890")
    assert_equal "6281234567890@s.whatsapp.net", built[:jid]

    interactive = built.dig(:message, :viewOnceMessage, :message, :interactiveMessage)
    assert_equal "Interactive Hub", interactive.dig(:header, :title)
    assert_equal "Welcome to Ruby WhatsApp automation", interactive.dig(:body, :text)
    assert_equal 1, interactive.dig(:nativeFlowMessage, :messageVersion)
    assert_equal 9, interactive.dig(:nativeFlowMessage, :buttons).size

    selection = interactive.dig(:nativeFlowMessage, :buttons).find { |b| b[:name] == "single_select" }
    parsed_sel = JSON.parse(selection[:buttonParamsJson])
    assert_equal "plan_pro", parsed_sel["sections"][0]["rows"][0]["id"]
  end

  def test_carousel_builder_creates_swipeable_cards
    c1 = BaileysRec::Button.new.set_title("Item 1").set_body("Desc 1").set_image("https://example.com/1.jpg").add_reply("Buy 1", "buy_1")
    c2 = BaileysRec::Button.new.set_title("Item 2").set_body("Desc 2").add_url("View", "https://example.com/2")

    carousel = BaileysRec::Carousel.new
                                     .set_title("Catalog")
                                     .set_body("Featured items")
                                     .add_card([c1, c2])

    built = carousel.build("6281234567890")
    inner = built.dig(:message, :viewOnceMessage, :message, :interactiveMessage)
    assert_equal 2, inner.dig(:carouselMessage, :cards).size
    assert_equal 1, inner.dig(:carouselMessage, :messageVersion)
    assert_equal true, inner.dig(:carouselMessage, :cards, 0, :header, :hasMediaAttachment)
  end

  def test_flow_builder_v3_schema_and_button
    flow = BaileysRec::FlowBuilder.new("survey_v3", "Customer Feedback")
                                  .add_screen("SURVEY_SCREEN", "Feedback")
                                  .add_text_input("name", "Your Name", required: true)
                                  .add_dropdown("rating", "Rating", %w[5 4 3])
                                  .add_footer("Submit", "complete")

    json = flow.build_json
    assert_equal "3.1", json[:version]
    assert_equal 1, json[:screens].size
    assert_equal 3, json[:screens][0][:layout][:children].size

    btn = flow.to_flow_button("Open Survey", "tok_99")
    assert_equal "flow", btn[:name]
    params = JSON.parse(btn[:buttonParamsJson])
    assert_equal "survey_v3", params["flow_id"]
    assert_equal "SURVEY_SCREEN", params["flow_action_payload"]["screen"]
  end
end
