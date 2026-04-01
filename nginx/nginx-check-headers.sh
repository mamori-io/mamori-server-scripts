#!/bin/sh
#
# Mamori LLC copyright 2026.
#
# Fetches HTTP response headers from the local HTTPS endpoint (nginx on localhost) for quick verification.

curl -sI -k https://localhost
