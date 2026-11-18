import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  Browsers,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  NewsletterHelper,
  fromCloudApiMessage
} from "baileys-rec";
import pino from "pino";
import readline from "node:readline";

let sock = null;
let saveCredsFn = null;
let currentAuthFolder = "./auth_info";
let currentOptions = {};
let reconnectTimer = null;
let reconnectAttempt = 0;
let shuttingDown = false;

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
