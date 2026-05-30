#!/bin/sh
# Xcode Cloud: trust third-party Swift macros (LLM.swift uses macro targets).
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
