#!/usr/bin/env swift
// Copies HTML content from stdin to clipboard as rich text.
// Usage: echo "<b>Hello</b>" | swift copy-html-to-clipboard.swift
// Or: swift copy-html-to-clipboard.swift < file.html

import AppKit
import Foundation

// Read HTML from stdin
let htmlContent = FileHandle.standardInput.readDataToEndOfFile()
guard let htmlString = String(data: htmlContent, encoding: .utf8), !htmlString.isEmpty else {
    fputs("Error: No HTML content provided on stdin\n", stderr)
    exit(1)
}

// Create plain text version by stripping HTML tags (basic approach)
var plainText = htmlString
    .replacingOccurrences(of: "<br>", with: "\n")
    .replacingOccurrences(of: "<br/>", with: "\n")
    .replacingOccurrences(of: "<br />", with: "\n")
    .replacingOccurrences(of: "</li>", with: "\n")
    .replacingOccurrences(of: "<li>", with: "• ")
    .replacingOccurrences(of: "</ul>", with: "\n")
    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(htmlString, forType: .html)
pasteboard.setString(plainText, forType: .string)

print("Copied to clipboard as rich text")
