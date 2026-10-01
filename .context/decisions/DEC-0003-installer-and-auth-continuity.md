# DEC-0003 — Upgradeable installer and ChatGPT authentication continuity

Date: 2026-10-01
Status: accepted
Authority: Owner directive + verified implementation evidence

## Decision

Distribute the Windows client primarily through a per-user Inno Setup installer with a stable AppId. A newer Setup updates the existing installation in place.

Keep application binaries under:
`%LOCALAPPDATA%\Programs\ChatGPT Desktop Local Bridge`

Keep WebView2 state under:
`%LOCALAPPDATA%\ChatGptDesktopLocalBridge\WebView2`

The WebView2 User Data Folder is not part of ordinary application upgrade and is the canonical ChatGPT authentication/session continuity mechanism.

## Yandex Browser session import

Do not make automatic copying/decryption of Yandex Browser cookies/profile data the normal authentication path. Yandex and WebView2 use separate browser profiles; browser-secret storage has no stable cross-application import contract and modern Chromium security can bind protected browser data to the originating application.

The supported approach is to authenticate once in the application's own WebView2 profile and preserve that profile across all upgrades.

A future explicit migration feature may be reconsidered only if a documented, robust, non-secret-extraction mechanism becomes available.

## Update scope

This decision guarantees in-place replacement when a newer Setup is executed. It does not yet implement background discovery/download/install of new releases.
