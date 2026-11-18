// Force baileys-rec to use the battle-tested `ws` client instead of Node's
// experimental Undici/HTTP2 globalThis.WebSocket (which throws code=500 on Termux/Node 24+).
globalThis.WebSocket = undefined;

import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  Browsers,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  NewsletterHelper,
  fromCloudApiMessage,
  buildInteractiveMessage
} from "baileys-rec";
import pino from "pino";
import readline from "node:readline";
import zlib from "node:zlib";

let sock = null;
let saveCredsFn = null;
let currentAuthFolder = "./auth_info";
let currentOptions = {};
let reconnectTimer = null;
let reconnectAttempt = 0;
let shuttingDown = false;
const messageStore = new Map();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}

function createCardBannerPng(w = 320, h = 180, r = 18, g = 140, b = 126) {
  const row = Buffer.alloc(1 + w * 3);
  row[0] = 0;
  for (let x = 0; x < w; x++) {
    row[1 + x * 3] = r;
    row[2 + x * 3] = g;
    row[3 + x * 3] = b;
  }
  const raw = Buffer.concat(Array.from({ length: h }, () => row));
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", zlib.deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0))
  ]);
}

const DEFAULT_CARD_PNG = createCardBannerPng();

function rememberMessage(fullMsg) {
  const id = fullMsg?.key?.id;
  if (!id || !fullMsg?.message) return;
  messageStore.set(id, fullMsg.message);
  if (messageStore.size > 500) {
    const oldestKey = messageStore.keys().next().value;
    if (oldestKey) messageStore.delete(oldestKey);
  }
}

const silentLogger = pino({ level: "silent" });

function sendFrame(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

function emitEvent(event, data) {
  sendFrame({ event, data });
}

async function initSocket(params = {}) {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  currentAuthFolder = params.authFolder || currentAuthFolder;
  currentOptions = params;
  shuttingDown = false;

  const { state, saveCreds } = await useMultiFileAuthState(currentAuthFolder);
  saveCredsFn = saveCreds;

  let waVersion;
  try {
    const latest = await fetchLatestBaileysVersion();
    if (latest?.version) waVersion = latest.version;
  } catch {
    waVersion = undefined;
  }

  const socketConfig = {
    auth: {
      creds: state.creds,
      keys: makeCacheableSignalKeyStore(state.keys, silentLogger)
    },
    printQRInTerminal: Boolean(params.printQRInTerminal),
    browser: Browsers.ubuntu("Chrome"),
    syncFullHistory: false,
    markOnlineOnConnect: true,
    generateHighQualityLinkPreview: true,
    getMessage: async (key) => messageStore.get(key?.id) || undefined,
    logger: silentLogger
  };
  if (waVersion) socketConfig.version = waVersion;

  sock = makeWASocket(socketConfig);

  sock.ev.on("creds.update", async () => {
    if (saveCredsFn) await saveCredsFn();
    emitEvent("creds.update", { saved: true });
  });

  sock.ev.on("connection.update", (update) => {
    const lastErr = update?.lastDisconnect?.error;
    const statusCode = lastErr?.output?.statusCode || lastErr?.statusCode || null;
    const errorMessage = lastErr?.message || null;

    if (update.connection === "open") {
      reconnectAttempt = 0;
    }

    emitEvent("connection.update", {
      connection: update.connection || null,
      qr: update.qr || null,
      registered: Boolean(state?.creds?.registered),
      me: sock?.user || state?.creds?.me || null,
      statusCode,
      error: errorMessage
    });

    if (!shuttingDown && update.connection === "close" && statusCode !== DisconnectReason.loggedOut) {
      reconnectAttempt += 1;
      const delayMs = Math.min(30000, 2500 * Math.pow(1.5, Math.min(reconnectAttempt - 1, 5)));
      reconnectTimer = setTimeout(() => {
        initSocket(currentOptions).catch((err) => {
          emitEvent("connection.update", { connection: "close", error: err.message });
        });
      }, delayMs);
    }
  });

  sock.ev.on("messages.upsert", (upsert) => {
    if (Array.isArray(upsert?.messages)) {
      for (const m of upsert.messages) rememberMessage(m);
    }
    emitEvent("messages.upsert", upsert);
  });

  sock.ev.on("messages.update", (updates) => {
    emitEvent("messages.update", updates);
  });

  sock.ev.on("group-participants.update", (ev) => {
    emitEvent("group_participants_update", ev);
  });

  return {
    status: "initialized",
    authFolder: currentAuthFolder,
    registered: Boolean(state?.creds?.registered),
    version: waVersion || null
  };
}

function requireSocket() {
  if (!sock) throw new Error("WhatsApp socket is not initialized");
  return sock;
}

function translateRichSubmessages(submessages = []) {
  return submessages.map((s) => {
    if (s.messageType === 2) {
      return { text: s.messageText || "", inlineEntities: s.inlineEntities };
    }
    if (s.messageType === 5 && s.codeMetadata) {
      return {
        language: s.codeMetadata.codeLanguage || "javascript",
        code: s.codeMetadata.codeBlocks || []
      };
    }
    if (s.messageType === 4 && s.tableMetadata) {
      return {
        title: s.tableMetadata.title || "",
        table: s.tableMetadata.rows || []
      };
    }
    if (s.messageType === 3 && s.imageUrl) {
      return { inlineImage: s.imageUrl };
    }
    if (s.messageType === 1 && Array.isArray(s.imageUrls) && s.imageUrls.length > 0) {
      return { inlineImage: s.imageUrls[0] };
    }
    return s;
  });
}

function prepareOutgoingPayload(content) {
  if (!content || typeof content !== "object") return content;

  // Convert Ruby AIRich payload into baileys-rec native richResponse so
  // botMetadata.verificationMetadata, forwardedAiBotMessageInfo, and Uint8Array bytes are built cleanly.
  const richMsg = content.botForwardedMessage?.message?.richResponseMessage;
  if (richMsg) {
    return {
      richResponse: translateRichSubmessages(richMsg.submessages || [])
    };
  }

  // Convert Ruby Carousel / Button payload into baileys-rec native high-level structure
  const interactive = content.viewOnceMessage?.message?.interactiveMessage;
  if (interactive?.carouselMessage) {
    const cards = (interactive.carouselMessage.cards || []).map((card) => {
      const hdr = card.header || {};
      const out = {
        title: hdr.title || "",
        subtitle: hdr.subtitle || "",
        text: card.body?.text || "",
        footer: card.footer?.text,
        nativeFlow: card.nativeFlowMessage?.buttons || []
      };
      if (hdr.image || hdr.imageMessage) {
        out.image = hdr.image || hdr.imageMessage;
      } else if (hdr.video || hdr.videoMessage) {
        out.video = hdr.video || hdr.videoMessage;
      } else if (hdr.document || hdr.documentMessage) {
        out.document = hdr.document || hdr.documentMessage;
      } else if (!hdr.product && !hdr.productMessage) {
        // WhatsApp Carousel cards require a media header (hasMediaAttachment: true)
        out.image = DEFAULT_CARD_PNG;
      }
      return out;
    });

    return {
      title: interactive.header?.title || "",
      subtitle: interactive.header?.subtitle || "",
      text: interactive.body?.text || "",
      footer: interactive.footer?.text,
      cards
    };
  }

  if (interactive?.nativeFlowMessage) {
    const hdr = interactive.header || {};
    const out = {
      title: hdr.title || "",
      subtitle: hdr.subtitle || "",
      text: interactive.body?.text || "",
      footer: interactive.footer?.text,
      nativeFlow: interactive.nativeFlowMessage.buttons || []
    };
    if (hdr.image || hdr.imageMessage) out.image = hdr.image || hdr.imageMessage;
    if (hdr.video || hdr.videoMessage) out.video = hdr.video || hdr.videoMessage;
    if (hdr.document || hdr.documentMessage) out.document = hdr.document || hdr.documentMessage;
    return out;
  }

  if (content.raw === undefined && content.buttonsMessage) {
    return { ...content, raw: true };
  }

  return content;
}

const handlers = {
  init: (p) => initSocket(p),
  sendMessage: async (p) => {
    const payload = prepareOutgoingPayload(p.content);
    const res = await requireSocket().sendMessage(p.jid, payload, p.options || {});
    rememberMessage(res);
    return res;
  },
  sendInteractive: async (p) => {
    const message = buildInteractiveMessage(p.content);
    const res = await requireSocket().sendMessage(p.jid, message, p.options || {});
    rememberMessage(res);
    return res;
  },
  sendCloudApi: async (p) => {
    const res = await requireSocket().sendMessage(p.jid, fromCloudApiMessage(p.payload), p.options || {});
    rememberMessage(res);
    return res;
  },
  requestPairingCode: async (p) => {
    const cleanPhone = String(p.phoneNumber || "").replace(/[^0-9]/g, "");
    const code = await requireSocket().requestPairingCode(cleanPhone, p.customCode || undefined);
    return { phoneNumber: cleanPhone, code };
  },
  sendPresenceUpdate: async (p) => requireSocket().sendPresenceUpdate(p.type, p.jid),
  onWhatsApp: async (p) => requireSocket().onWhatsApp(...(p.phoneNumbers || [])),
  groupCreate: async (p) => requireSocket().groupCreate(p.subject, p.participants || []),
  groupMetadata: async (p) => requireSocket().groupMetadata(p.jid),
  groupParticipantsUpdate: async (p) => requireSocket().groupParticipantsUpdate(p.jid, p.participants || [], p.action),
  newsletterFollow: async (p) => NewsletterHelper.follow(requireSocket(), p.jid),
  newsletterUnfollow: async (p) => NewsletterHelper.unfollow(requireSocket(), p.jid),
  newsletterMute: async (p) => NewsletterHelper.mute(requireSocket(), p.jid),
  newsletterUnmute: async (p) => NewsletterHelper.unmute(requireSocket(), p.jid),
  newsletterMetadata: async (p) => NewsletterHelper.getMetadata(requireSocket(), p.jid),
  query: async (p) => requireSocket().query(p.node),
  logout: async () => requireSocket().logout(),
  shutdown: async () => {
    shuttingDown = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    if (sock) await sock.end(undefined);
    setTimeout(() => process.exit(0), 50);
    return { shutdown: true };
  }
};

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;

  let req;
  try {
    req = JSON.parse(trimmed);
  } catch {
    return;
  }

  const { id, method, params } = req;
  try {
    const fn = handlers[method];
    if (!fn) throw new Error(`Unknown RPC method: ${method}`);
    const result = await fn(params || {});
    sendFrame({ id, result });
  } catch (err) {
    sendFrame({
      id,
      error: {
        message: err?.message || String(err),
        code: err?.output?.statusCode || err?.statusCode || 500
      }
    });
  }
});
