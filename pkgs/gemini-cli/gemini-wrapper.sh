#!/bin/bash
export NODE_OPTIONS="--no-deprecation"
exec /usr/lib/node_modules/@google/gemini-cli/bundle/gemini.js "$@"
