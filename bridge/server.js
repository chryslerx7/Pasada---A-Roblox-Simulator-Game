const express = require("express");

const app = express();
const PORT = 3847;

app.use(express.json());

let commandQueue = [];

app.get("/health", (req, res) => {
    res.json({
        success: true,
        service: "RobloxAI Bridge",
        status: "online"
    });
});

app.post("/command", (req, res) => {
    const command = req.body;

    console.log("Received command:");
    console.log(JSON.stringify(command, null, 2));

    commandQueue.push(command);

    res.json({
        success: true,
        message: "Command received"
    });
});

app.get("/commands", (req, res) => {
    const commands = [...commandQueue];
    commandQueue = [];

    res.json({
        success: true,
        commands
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