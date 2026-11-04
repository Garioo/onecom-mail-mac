#!/bin/bash
# Compiles the mail parsing code with the checks and runs them.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -swift-version 5 -parse-as-library MailMIME.swift MailIMAP.swift checks/ThreadsCheck.swift -o "$out/check" 2>&1 | grep -v warning || true
"$out/check"
