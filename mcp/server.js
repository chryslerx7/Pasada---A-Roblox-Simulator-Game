import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const app = express();

const PORT = 3850;
const BRIDGE_URL = "http://127.0.0.1:3847";
const DEFAULT_WAIT_MS = 10000;
const POLL_INTERVAL_MS = 500;

app.use(express.json());

function generateId() {
    return `cmd-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function postCommand(id, action, data) {
    const response = await fetch(`${BRIDGE_URL}/command`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, action, data }),
    });
    if (!response.ok) {
        const text = await response.text().catch(() => "");
        throw new Error(`Roblox Bridge returned HTTP ${response.status}: ${text}`);
    }
    return response.json();
}

async function getCommand(id) {
    const response = await fetch(`${BRIDGE_URL}/commands/${encodeURIComponent(id)}`);
    if (!response.ok) {
        throw new Error(`Bridge returned HTTP ${response.status} for command ${id}`);
    }
    const body = await response.json();
    return body.command;
}

// Send command and wait for Studio plugin to report success/failed.
// Returns { id, completed, status, result, error }.
// Does NOT pretend success when Studio has not executed the command.
async function sendCommandAndWait(action, data, timeoutMs = DEFAULT_WAIT_MS) {
    const id = generateId();
    await postCommand(id, action, data);

    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        await sleep(POLL_INTERVAL_MS);
        let cmd;
        try {
            cmd = await getCommand(id);
        } catch {
            continue;
        }
        if (cmd.status === "success" || cmd.status === "failed") {
            return {
                id,
                completed: true,
                status: cmd.status,
                result: cmd.result,
                error: cmd.error,
            };
        }
    }

    // Timeout: report queued/executing state honestly
    let final = null;
    try {
        final = await getCommand(id);
    } catch {
        // ignore
    }
    return {
        id,
        completed: false,
        status: final ? final.status : "unknown",
        result: null,
        error: `Timed out after ${timeoutMs}ms waiting for Studio. Command ${id} is '${final ? final.status : "unknown"}'. Is Roblox Studio + plugin running?`,
    };
}

function formatSuccess(action, id, detail) {
    return {
        content: [
            {
                type: "text",
                text: `Success: ${action} (${id})\n${detail || ""}`.trim(),
            },
        ],
    };
}

function formatFailure(action, id, error) {
    return {
        content: [
            {
                type: "text",
                text: `Failed: ${action} (${id}): ${error || "unknown error"}`,
            },
        ],
        isError: true,
    };
}

function createMcpServer() {
    const server = new McpServer({
        name: "RobloxAI",
        version: "1.0.0",
    });

    // ---- 1. CREATE PART (preserved + extended) ----
    server.registerTool(
        "roblox_create_part",
        {
            description: "Create an anchored Part inside Roblox Studio. Waits for Studio confirmation.",
            inputSchema: {
                name: z.string().optional(),
                parent: z.string().optional().describe("Parent path, e.g. Workspace or Workspace.Folder. Defaults to Workspace."),
                position: z.array(z.number()).length(3),
                size: z.array(z.number()).length(3),
                anchored: z.boolean().optional(),
                material: z.string().optional().describe("Enum.Material name, e.g. SmoothPlastic, Neon, Wood"),
                transparency: z.number().min(0).max(1).optional(),
                color: z.array(z.number()).length(3).optional().describe("RGB 0-255, e.g. [255,0,0]"),
            },
        },
        async ({ name, parent, position, size, anchored, material, transparency, color }) => {
            const data = {
                name: name || "AI_Part",
                parent: parent || "Workspace",
                position,
                size,
            };
            if (anchored !== undefined) data.anchored = anchored;
            if (material !== undefined) data.material = material;
            if (transparency !== undefined) data.transparency = transparency;
            if (color !== undefined) data.color = color;

            try {
                const outcome = await sendCommandAndWait("create_part", data);
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess(
                        "create_part",
                        outcome.id,
                        `Part: ${data.name}\nPosition: ${position.join(", ")}\nSize: ${size.join(", ")}\nResult: ${JSON.stringify(outcome.result)}`
                    );
                }
                return formatFailure("create_part", outcome.id, outcome.error);
            } catch (error) {
                return {
                    content: [{ type: "text", text: `Failed to communicate with Roblox Bridge: ${error.message}` }],
                    isError: true,
                };
            }
        }
    );

    // ---- 2. CREATE FOLDER ----
    server.registerTool(
        "roblox_create_folder",
        {
            description: "Create a Folder under a parent path in Roblox Studio.",
            inputSchema: {
                name: z.string().min(1),
                parent: z.string().min(1).describe("Parent path, e.g. ServerScriptService or Workspace"),
            },
        },
        async ({ name, parent }) => {
            try {
                const outcome = await sendCommandAndWait("create_folder", { name, parent });
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess("create_folder", outcome.id, `Folder: ${parent}.${name}\nResult: ${JSON.stringify(outcome.result)}`);
                }
                return formatFailure("create_folder", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 3. CREATE SCRIPT ----
    server.registerTool(
        "roblox_create_script",
        {
            description: "Create a Script, LocalScript, or ModuleScript with Source in Roblox Studio.",
            inputSchema: {
                name: z.string().min(1),
                scriptType: z.enum(["Script", "LocalScript", "ModuleScript"]),
                parent: z.string().min(1).describe("Parent path, e.g. ServerScriptService.Services"),
                source: z.string().optional().describe("Lua/Luau source code"),
            },
        },
        async ({ name, scriptType, parent, source }) => {
            try {
                const outcome = await sendCommandAndWait("create_script", {
                    name,
                    scriptType,
                    parent,
                    source: source ?? "",
                });
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess("create_script", outcome.id, `${scriptType}: ${parent}.${name}\nResult: ${JSON.stringify(outcome.result)}`);
                }
                return formatFailure("create_script", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 4. CREATE MODEL ----
    server.registerTool(
        "roblox_create_model",
        {
            description: "Create a Model under a parent path in Roblox Studio.",
            inputSchema: {
                name: z.string().min(1),
                parent: z.string().min(1).describe("Parent path, e.g. Workspace.Vehicles"),
            },
        },
        async ({ name, parent }) => {
            try {
                const outcome = await sendCommandAndWait("create_model", { name, parent });
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess("create_model", outcome.id, `Model: ${parent}.${name}\nResult: ${JSON.stringify(outcome.result)}`);
                }
                return formatFailure("create_model", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 5. SET PROPERTY (controlled whitelist) ----
    server.registerTool(
        "roblox_set_property",
        {
            description: "Set a whitelisted safe property (Name, Anchored, Transparency, CanCollide, Size, Position, Color, Material) on an object.",
            inputSchema: {
                path: z.string().min(1).describe("Object path, e.g. Workspace.TestPart"),
                property: z.enum(["Name", "Anchored", "Transparency", "CanCollide", "Size", "Position", "Color", "Material"]),
                value: z.any().describe("New value. Vector3 as [x,y,z], Color as [r,g,b] 0-255, Material as string, booleans/numbers/strings otherwise."),
            },
        },
        async ({ path, property, value }) => {
            try {
                const outcome = await sendCommandAndWait("set_property", { path, property, value });
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess("set_property", outcome.id, `${path}.${property} updated\nResult: ${JSON.stringify(outcome.result)}`);
                }
                return formatFailure("set_property", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 6. INSPECT OBJECT ----
    server.registerTool(
        "roblox_inspect_object",
        {
            description: "Inspect an object in Roblox Studio. Returns Name, ClassName, path, children, and relevant properties.",
            inputSchema: {
                path: z.string().min(1).describe("Object path, e.g. Workspace"),
            },
        },
        async ({ path }) => {
            try {
                const outcome = await sendCommandAndWait("inspect_object", { path });
                if (outcome.completed && outcome.status === "success") {
                    return {
                        content: [{ type: "text", text: `Inspect ${path} (${outcome.id}):\n${JSON.stringify(outcome.result, null, 2)}` }],
                    };
                }
                return formatFailure("inspect_object", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 7. DELETE OBJECT ----
    server.registerTool(
        "roblox_delete_object",
        {
            description: "Delete an object at a validated path. Refuses to delete top-level services.",
            inputSchema: {
                path: z.string().min(1).describe("Object path, e.g. Workspace.TestPart"),
            },
        },
        async ({ path }) => {
            try {
                const outcome = await sendCommandAndWait("delete_object", { path });
                if (outcome.completed && outcome.status === "success") {
                    return formatSuccess("delete_object", outcome.id, `Deleted: ${path}\nResult: ${JSON.stringify(outcome.result)}`);
                }
                return formatFailure("delete_object", outcome.id, outcome.error);
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    // ---- 8. COMMAND STATUS ----
    server.registerTool(
        "roblox_command_status",
        {
            description: "Check the queued/executing/success/failed status of a command ID.",
            inputSchema: {
                id: z.string().min(1),
            },
        },
        async ({ id }) => {
            try {
                const cmd = await getCommand(id);
                return {
                    content: [{ type: "text", text: `Command ${id}:\n${JSON.stringify(cmd, null, 2)}` }],
                };
            } catch (error) {
                return { content: [{ type: "text", text: `Bridge error: ${error.message}` }], isError: true };
            }
        }
    );

    return server;
}

app.post("/mcp", async (req, res) => {
    try {
        const server = createMcpServer();
        const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: undefined,
        });
        await server.connect(transport);
        await transport.handleRequest(req, res, req.body);
    } catch (error) {
        console.error("[RobloxAI MCP] Error:");
        console.error(error);
        if (!res.headersSent) {
            res.status(500).json({
                error: "MCP server error",
                message: error.message,
            });
        }
    }
});

app.get("/", (req, res) => {
    res.json({
        success: true,
        service: "RobloxAI MCP Server",
        status: "online",
    });
});

app.listen(PORT, "127.0.0.1", () => {
    console.log("----------------------------------------");
    console.log(" RobloxAI MCP Server");
    console.log("----------------------------------------");
    console.log(`Running on http://127.0.0.1:${PORT}`);
    console.log(`MCP endpoint: http://127.0.0.1:${PORT}/mcp`);
    console.log("----------------------------------------");
});
