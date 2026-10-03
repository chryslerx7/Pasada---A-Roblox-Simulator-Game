import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const app = express();

const PORT = 3850;
const BRIDGE_URL = "http://127.0.0.1:3847";

app.use(express.json());

function createMcpServer() {
    const server = new McpServer({
        name: "RobloxAI",
        version: "1.0.0"
    });

    server.registerTool(
        "roblox_create_part",
        {
            description: "Create an anchored Part inside Roblox Studio.",
            inputSchema: {
                name: z.string().optional(),
                position: z.array(z.number()).length(3),
                size: z.array(z.number()).length(3)
            }
        },
        async ({ name, position, size }) => {

            const command = {
                action: "create_part",

                data: {
                    name: name || "AI_Part",
                    position,
                    size
                }
            };

            try {
                const response = await fetch(
                    `${BRIDGE_URL}/command`,
                    {
                        method: "POST",

                        headers: {
                            "Content-Type": "application/json"
                        },

                        body: JSON.stringify(command)
                    }
                );

                if (!response.ok) {
                    throw new Error(
                        `Roblox Bridge returned HTTP ${response.status}`
                    );
                }

                return {
                    content: [
                        {
                            type: "text",
                            text:
                                `Successfully sent command to Roblox Studio.\n` +
                                `Part: ${command.data.name}\n` +
                                `Position: ${position.join(", ")}\n` +
                                `Size: ${size.join(", ")}`
                        }
                    ]
                };

            } catch (error) {

                return {
                    content: [
                        {
                            type: "text",
                            text:
                                `Failed to communicate with Roblox Bridge: ${error.message}`
                        }
                    ],
                    isError: true
                };
            }
        }
    );

    return server;
}

app.post("/mcp", async (req, res) => {

    try {

        const server = createMcpServer();

        const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: undefined
        });

        await server.connect(transport);

        await transport.handleRequest(
            req,
            res,
            req.body
        );

    } catch (error) {

        console.error("[RobloxAI MCP] Error:");
        console.error(error);

        if (!res.headersSent) {
            res.status(500).json({
                error: "MCP server error",
                message: error.message
            });
        }
    }
});

app.get("/", (req, res) => {

    res.json({
        success: true,
        service: "RobloxAI MCP Server",
        status: "online"
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