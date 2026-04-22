const WebSocket = require("ws");

const PORT = Number(process.env.PORT || 8787);
const STALE_MS = 15000;
const PRUNE_INTERVAL_MS = 5000;

const wss = new WebSocket.Server({ port: PORT });

// in memory presence map
// sessions: sessionCode -> (userId -> member)
const sessions = new Map();

// connection index
// ws -> { session, userId }
const connectionMeta = new Map();

function getSessionMembers(sessionCode) {
  if (!sessions.has(sessionCode)) {
    sessions.set(sessionCode, new Map());
  }
  return sessions.get(sessionCode);
}

function sendJSON(ws, payload) {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(payload));
}

function broadcastToSession(sessionCode, payload) {
  const message = JSON.stringify(payload);
  for (const [ws, meta] of connectionMeta.entries()) {
    if (!meta || meta.session !== sessionCode) continue;
    if (ws.readyState !== WebSocket.OPEN) continue;
    ws.send(message);
  }
}

function buildMemberFromMessage(msg) {
  return {
    userId: String(msg.userId || ""),
    name: String(msg.name || "Driver"),
    lat: Number(msg.lat),
    lng: Number(msg.lng),
    speedMPS: Number.isFinite(Number(msg.speedMPS)) ? Number(msg.speedMPS) : null,
    heading: Number.isFinite(Number(msg.heading)) ? Number(msg.heading) : null,
    timestamp: Number(msg.timestamp || Date.now())
  };
}

function removeMember(sessionCode, userId) {
  if (!sessionCode || !userId) return;
  const sessionMembers = sessions.get(sessionCode);
  if (!sessionMembers) return;

  sessionMembers.delete(userId);
  if (sessionMembers.size === 0) {
    sessions.delete(sessionCode);
  }

  broadcastToSession(sessionCode, {
    type: "left",
    userId
  });
}

function handleJoin(ws, msg) {
  const sessionCode = String(msg.session || "").trim();
  const userId = String(msg.userId || "").trim();

  if (!sessionCode || !userId) {
    sendJSON(ws, { type: "status", message: "Join rejected: missing session/userId" });
    return;
  }

  const sessionMembers = getSessionMembers(sessionCode);
  const existing = sessionMembers.get(userId) || {};

  const member = {
    userId,
    name: String(msg.name || existing.name || "Driver"),
    lat: Number.isFinite(Number(existing.lat)) ? Number(existing.lat) : null,
    lng: Number.isFinite(Number(existing.lng)) ? Number(existing.lng) : null,
    speedMPS: existing.speedMPS ?? null,
    heading: existing.heading ?? null,
    timestamp: Number(existing.timestamp || Date.now())
  };

  sessionMembers.set(userId, member);
  connectionMeta.set(ws, { session: sessionCode, userId });

  sendJSON(ws, {
    type: "snapshot",
    members: Array.from(sessionMembers.values())
  });

  broadcastToSession(sessionCode, {
    type: "presence",
    member
  });
}

function handleUpdate(ws, msg) {
  const sessionCode = String(msg.session || "").trim();
  const userId = String(msg.userId || "").trim();
  if (!sessionCode || !userId) return;

  const sessionMembers = getSessionMembers(sessionCode);
  const incoming = buildMemberFromMessage(msg);
  if (!Number.isFinite(incoming.lat) || !Number.isFinite(incoming.lng)) return;

  sessionMembers.set(userId, incoming);
  connectionMeta.set(ws, { session: sessionCode, userId });

  broadcastToSession(sessionCode, {
    type: "presence",
    member: incoming
  });
}

function handleLeave(msg) {
  const sessionCode = String(msg.session || "").trim();
  const userId = String(msg.userId || "").trim();
  removeMember(sessionCode, userId);
}

wss.on("connection", (ws) => {
  sendJSON(ws, { type: "status", message: "Connected to DashCam convoy server" });

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return;
    }

    if (!msg || typeof msg !== "object") return;

    switch (msg.type) {
      case "join":
        handleJoin(ws, msg);
        break;
      case "update":
        handleUpdate(ws, msg);
        break;
      case "leave":
        handleLeave(msg);
        break;
      default:
        break;
    }
  });

  ws.on("close", () => {
    const meta = connectionMeta.get(ws);
    if (meta) {
      removeMember(meta.session, meta.userId);
    }
    connectionMeta.delete(ws);
  });
});

setInterval(() => {
  const now = Date.now();

  for (const [sessionCode, members] of sessions.entries()) {
    for (const [userId, member] of members.entries()) {
      const age = now - Number(member.timestamp || 0);
      if (age > STALE_MS) {
        members.delete(userId);
        broadcastToSession(sessionCode, { type: "left", userId });
      }
    }

    if (members.size === 0) {
      sessions.delete(sessionCode);
    }
  }
}, PRUNE_INTERVAL_MS);

console.log(`DashCam convoy server running on ws://0.0.0.0:${PORT}`);
