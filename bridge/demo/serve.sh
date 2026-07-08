#!/bin/bash
# Serves the demo shop on http://localhost:8873 (the helper accepts plain-http
# origins for localhost only — see BridgeMessage.isAcceptableOrigin).
cd "$(dirname "$0")" && exec python3 -m http.server 8873
