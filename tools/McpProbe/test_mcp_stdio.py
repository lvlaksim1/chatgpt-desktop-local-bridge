"""End-to-end stdio MCP smoke test with no third-party Python dependencies."""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
dll = root / "bin" / "Release" / "net8.0" / "McpProbe.dll"
if not dll.is_file():
    raise SystemExit(f"Build the MCP probe first: {dll}")

process = subprocess.Popen(
    ["dotnet", str(dll)],
    cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1
)
assert process.stdin is not None and process.stdout is not None
try:
    def request(message):
        process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("MCP server closed stdout without answering")
            result = json.loads(line)
            if result.get("id") == message.get("id"):
                if "error" in result:
                    raise RuntimeError(f"MCP error: {result['error']}")
                return result["result"]

    init = request({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "chatgpt-bridge-probe-test", "version": "0.1.0"}
    }})
    print("INITIALIZE_OK", init.get("protocolVersion", "unknown"))
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    process.stdin.flush()
    tools = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = [tool["name"] for tool in tools["tools"]]
    print("TOOLS", names)
    assert "bridge_ping" in names, "bridge_ping missing from tools/list"
    call = request({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": {"name": "bridge_ping", "arguments": {}}})
    message = json.dumps(call, ensure_ascii=False)
    assert "CHATGPT_DESKTOP_LOCAL_BRIDGE_MCP_PING_OK" in message, message
    print("CALL_OK CHATGPT_DESKTOP_LOCAL_BRIDGE_MCP_PING_OK")
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
