# frozen_string_literal: true

require_relative "test_helper"

class CloudApiTest < Minitest::Test
  def test_sanitize_whatsapp_number
    assert_equal "6281234567890", BaileysRec.sanitize_whatsapp_number("+62 812-3456-7890")
    assert_equal "6281234567890", BaileysRec.sanitize_whatsapp_number("6281234567890@s.whatsapp.net")
    assert_equal "6281234567890", BaileysRec.sanitize_whatsapp_number("081234567890")
    assert_equal "14155552671", BaileysRec.sanitize_whatsapp_number("14155552671")
  end

  def test_from_cloud_api_interactive_buttons
    payload = {
      messaging_product: "whatsapp",
      to: "6281234567890",
      type: "interactive",
      interactive: {
        type: "button",
        header: { type: "text", text: "Important Notice" },
        body: { text: "Confirm booking?" },
        footer: { text: "baileys_rec" },
        action: {
          buttons: [
            { type: "reply", reply: { id: "btn_yes", title: "Yes" } },
            { type: "reply", reply: { id: "btn_no", title: "No" } }
          ]
        }
      }
    }

    converted = BaileysRec.from_cloud_api_message(payload)
    assert_equal "Important Notice", converted[:title]
    assert_equal "Confirm booking?", converted[:text]
    assert_equal "baileys_rec", converted[:footer]
    assert_equal 2, converted[:nativeFlow].size
    assert_equal "btn_yes", converted[:nativeFlow][0][:id]
  end

  def test_to_cloud_api_message_splits_excess_buttons_to_list
    baileys = {
      title: "Menu",
      text: "Choose an item",
      nativeFlow: (1..4).map { |i| { id: "opt_#{i}", text: "Item #{i}" } }
    }

    cloud = BaileysRec.to_cloud_api_message(baileys, "+6281234567890")
    assert_equal "interactive", cloud[:type]
    assert_equal "list", cloud[:interactive][:type]
    assert_equal 4, cloud[:interactive][:action][:sections][0][:rows].size
  end

  def test_diagnose_meta_cloud_api_error
    diag = BaileysRec.diagnose_meta_cloud_api_error({ code: 131_047, message: "Re-engagement message" })
    assert_equal 131_047, diag[:code]
    assert_includes diag[:title], "24h Rule"
  end

  def test_generate_waveform_and_serialize_message
    wf = BaileysRec.generate_waveform(64, min: 10, max: 90)
    assert_equal 64, wf.size
    assert wf.all? { |v| v >= 10 && v <= 90 }

    serialized = BaileysRec.serialize_message(
      key: { remoteJid: "628123@s.whatsapp.net", id: "ABC1", fromMe: false },
      pushName: "Budi",
      message: {
        interactiveResponseMessage: {
          body: { text: "Selected" },
          nativeFlowResponseMessage: { name: "quick_reply", paramsJson: '{"id":"buy_now"}' }
        }
      }
    )

    assert_equal "buy_now", serialized[:interactive][:id]
    assert_equal "Budi", serialized[:push_name]
  end
end
