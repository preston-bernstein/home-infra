import base64
import os
import httpx
from fastmcp import FastMCP

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
VISION_MODEL = os.getenv("VISION_MODEL", "llava:13b")
LIBRECHAT_HOST = os.getenv("LIBRECHAT_HOST", "http://localhost:3080")
MCP_PORT = int(os.getenv("MCP_PORT", "3003"))

mcp = FastMCP("vision")


async def _to_base64(image: str) -> str:
    async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
        if image.startswith("data:"):
            return image.split(",", 1)[1]
        if image.startswith("/api/"):
            resp = await client.get(f"{LIBRECHAT_HOST}{image}")
        else:
            resp = await client.get(image)
        resp.raise_for_status()
        return base64.b64encode(resp.content).decode()


@mcp.tool()
async def describe_image(image: str, prompt: str = "Describe this image in detail.") -> str:
    """Analyze an image with the local vision model (llava:13b).

    image: URL (http/https), LibreChat file path (/api/files/...), or base64 data URI.
    prompt: what to ask about the image.
    """
    image_b64 = await _to_base64(image)

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{OLLAMA_HOST}/api/generate",
            json={
                "model": VISION_MODEL,
                "prompt": prompt,
                "images": [image_b64],
                "stream": False,
            },
        )
        resp.raise_for_status()
        return resp.json()["response"]


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=MCP_PORT,
        path="/mcp",
    )
