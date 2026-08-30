#!/usr/bin/env bash
# The one place Memoir's version number lives. Sourced, never executed.
#
# It used to be a literal in build-app.sh, which was harmless while the app bundle was the
# only artefact anyone built. It stopped being harmless the moment there were three: the
# Info.plist inside Memoir.app, the `version` field in the .mcpb manifest, and the file name
# of the DMG all have to agree, and a reader has no way to tell a mismatch from a deliberate
# choice. Three literals that must match are three chances to hand someone a DMG named
# 0.1.0 containing an 0.2.0 app, and the only symptom is a bug report about a version number.
#
# Bump here and nowhere else.
MEMOIR_VERSION="0.4.0"
