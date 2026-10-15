#!/usr/bin/env python3
"""Live Gateway image capability controls; uses only synthetic color images.

Mirrors @ai-sdk/gateway 4.0.114's decision-model wire format. Credentials
come from research.py and are never saved. Results stay in ignored build/.
"""
import base64
import io
import json

from PIL import Image
from research import OUT, request

QUESTIONS = {"color": {
    "type": "choice",
    "instructions": "What color is the rectangle in the provided photo? If no photo is available, choose unknown.",
    "criteria": {"red": "Red", "blue": "Blue", "green": "Green", "unknown": "Cannot determine"},
}}
HEADERS = {
    "Content-Type": "application/json",
    "ai-gateway-protocol-version": "0.0.1",
    "ai-gateway-auth-method": "api-key",
    "ai-decision-model-specification-version": "4",
    "ai-model-id": "typesafe-ai/jev",
}


def main():
    results = []
    for color in [None, "red", "blue", "green"]:
        parts = [{"type": "text", "text": "Inspect the provided photo."}]
        if color:
            buf = io.BytesIO()
            Image.new("RGB", (560, 560), color).save(buf, "PNG")
            parts.append({"type": "file", "mediaType": "image/png", "filename": "photo.png",
                          "data": {"type": "data", "data": base64.b64encode(buf.getvalue()).decode()}})
        body = {"stateParts": parts, "questions": QUESTIONS}
        status, raw, ms = request("https://ai-gateway.vercel.sh/v4/ai/decision-model",
                                  json.dumps(body).encode(), True, HEADERS)
        try:
            response = json.loads(raw)
        except ValueError:
            response = raw.decode(errors="replace")
        result = {"color": color, "status": status, "elapsed_ms": ms, "response": response}
        results.append(result)
        (OUT / "gateway-v4-image-controls.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        if status != 200:
            break


if __name__ == "__main__":
    main()
