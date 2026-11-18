import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  NewsletterHelper,
  fromCloudApiMessage
} from "baileys-rec";
import pino from "pino";
import readline from "node:readline";

let sock = null;
let saveCredsFn = null;
let currentAuthFolder = "./auth_info";
let currentOptions = {};

function sendFrame(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

function emitEvent(event, data) {
  sendFrame({ event, data });
}

async function initSocket(params = {}) {
  currentAuthFolder = params.authFolder || currentAuthFolder;
  currentOptions = params;

  const { state, saveCreds } = await useMultiFileAuthState(currentAuthFolder);
  saveCredsFn = saveCreds;

  sock = makeWASocket({
    auth: state,
    printQRInTerminal: Boolean(params.printQRInTerminal),
    browser: params.browser || ["BaileysRecRuby", "Chrome", "1.6.0"],
    logger: pino({ level: "silent" })
  });

  sock.ev.on("creds.update", async () => {
    if (saveCredsFn) await saveCredsFn();
    emitEvent("creds.update", { saved: true });
  });

  sock.ev.on("connection.update", (update) => {
    const statusCode = update?.lastDisconnect?.error?.output?.statusCode;
    emitEvent("connection.update", {
      connection: update.connection,
      qr: update.qr || null,
      registered: Boolean(state?.creds?.registered),
      statusCode: statusCode || null
    });

    if (update.connection === "close" && statusCode !== DisconnectReason.loggedOut) {
      setTimeout(() => {
        initSocket(currentOptions).catch((err) => {
          emitEvent("connection.update", { connection: "close", error: err.message });
        });
      }, 2500);
    }
  });

  sock.ev.on("messages.upsert", (upsert) => {
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
    registered: Boolean(state?.creds?.registered)
  };
}

function requireSocket() {
  if (!sock) throw new Error("WhatsApp socket is not initialized");
  return sock;
}

const handlers = {
  init: (p) => initSocket(p),
  sendMessage: async (p) => requireSocket().sendMessage(p.jid, p.content, p.options || {}),
  sendInteractive: async (p) => {
    const s = requireSocket();
    if (typeof s.sendInteractive === "function") {
      return s.sendInteractive(p.jid, p.content, p.options?.quoted || null);
    }
    return s.sendMessage(p.jid, p.content, p.options || {});
  },
  sendCloudApi: async (p) => requireSocket().sendMessage(p.jid, fromCloudApiMessage(p.payload), p.options || {}),
  requestPairingCode: async (p) => {
    const code = await requireSocket().requestPairingCode(p.phoneNumber, p.customCode || undefined);
    return { phoneNumber: p.phoneNumber, code };
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
