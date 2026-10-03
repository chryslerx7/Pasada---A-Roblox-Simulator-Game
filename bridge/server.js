const express = require("express");

const app = express();
const PORT = 3847;

app.use(express.json());

// In-memory command store: id -> record
// record: { id, action, data, status, queuedAt, updatedAt, result, error }
const commands = new Map();

const ALLOWED_ACTIONS = new Set([
    "create_folder",
    "create_script",
    "create_model",
    "create_part",
    "set_property",
    "inspect_object",
    "delete_object",
]);

function generateId() {
    return `cmd-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

app.get("/health", (req, res) => {
    res.json({
        success: true,
        service: "RobloxAI Bridge",
        status: "online",
    });
});

// Submit a new command (called by MCP server)
app.post("/command", (req, res) => {
    const body = req.body || {};
    let { id, action, data } = body;

    if (!action || typeof action !== "string") {
        return res.status(400).json({
            success: false,
            error: "Missing required field: action (string)",
        });
    }

    if (!ALLOWED_ACTIONS.has(action)) {
        return res.status(400).json({
            success: false,
            error: `Unsupported action: ${action}. Allowed: ${[...ALLOWED_ACTIONS].join(", ")}`,
        });
    }

    if (data === undefined || data === null) {
        data = {};
    }

    if (typeof data !== "object" || Array.isArray(data)) {
        return res.status(400).json({
            success: false,
            error: "Field 'data' must be an object",
        });
    }

    if (id === undefined || id === null || id === "") {
        id = generateId();
    }

    if (typeof id !== "string") {
        return res.status(400).json({
            success: false,
            error: "Field 'id' must be a string",
        });
    }

    if (commands.has(id)) {
        return res.status(409).json({
            success: false,
            error: `Command ID already exists: ${id}`,
        });
    }

    const now = new Date().toISOString();
    const record = {
        id,
        action,
        data,
        status: "queued",
        queuedAt: now,
        updatedAt: now,
        result: null,
        error: null,
    };

    commands.set(id, record);

    console.log(`[Bridge] Queued ${id} action=${action}`);
    console.log(JSON.stringify(data, null, 2));

    res.json({
        success: true,
        id,
        status: "queued",
        message: "Command queued",
    });
});

// Poll for queued commands (called by Roblox Studio plugin).
// Returns queued commands and marks them as executing.
app.get("/commands", (req, res) => {
    const queued = [...commands.values()]
        .filter((c) => c.status === "queued")
        .sort((a, b) => a.queuedAt.localeCompare(b.queuedAt));

    const now = new Date().toISOString();
    for (const cmd of queued) {
        cmd.status = "executing";
        cmd.updatedAt = now;
    }

    res.json({
        success: true,
        commands: queued.map((c) => ({
            id: c.id,
            action: c.action,
            data: c.data,
        })),
    });
});

// Get a single command with status/result (called by MCP to verify execution)
app.get("/commands/:id", (req, res) => {
    const cmd = commands.get(req.params.id);
    if (!cmd) {
        return res.status(404).json({
            success: false,
            error: `Command not found: ${req.params.id}`,
        });
    }
    res.json({
        success: true,
        command: cmd,
    });
});

// Back-compat alias: GET /command/:id
app.get("/command/:id", (req, res) => {
    const cmd = commands.get(req.params.id);
    if (!cmd) {
        return res.status(404).json({
            success: false,
            error: `Command not found: ${req.params.id}`,
        });
    }
    res.json({
        success: true,
        command: cmd,
    });
});

function handleResult(req, res) {
    const id = req.params.id || (req.body && req.body.id);
    if (!id) {
        return res.status(400).json({
            success: false,
            error: "Missing command id",
        });
    }
    const cmd = commands.get(id);
    if (!cmd) {
        return res.status(404).json({
            success: false,
            error: `Command not found: ${id}`,
        });
    }

    const { success, result, error } = req.body || {};
    if (typeof success !== "boolean") {
        return res.status(400).json({
            success: false,
            error: "Field 'success' (boolean) is required",
        });
    }

    cmd.status = success ? "success" : "failed";
    cmd.result = result !== undefined ? result : null;
    cmd.error = !success ? (error || "Unknown error") : null;
    cmd.updatedAt = new Date().toISOString();

    console.log(`[Bridge] Result ${id} -> ${cmd.status}${cmd.error ? `: ${cmd.error}` : ""}`);

    res.json({
        success: true,
        id,
        status: cmd.status,
    });
}

// Plugin reports execution outcome
app.post("/commands/:id/result", handleResult);
app.post("/result", handleResult);

// History for debugging (newest first, limited)
app.get("/history", (req, res) => {
    const limit = Math.min(parseInt(req.query.limit || "50", 10) || 50, 200);
    const all = [...commands.values()].sort((a, b) => b.queuedAt.localeCompare(a.queuedAt));
    res.json({
        success: true,
        count: all.length,
        commands: all.slice(0, limit),
    });
});

app.listen(PORT, "127.0.0.1", () => {
    console.log("----------------------------------------");
    console.log(" Pasada Bridge");
    console.log("----------------------------------------");
    console.log(`Running on http://127.0.0.1:${PORT}`);
    console.log("");
    console.log("Health:");
    console.log(`http://127.0.0.1:${PORT}/health`);
    console.log("----------------------------------------");
});
