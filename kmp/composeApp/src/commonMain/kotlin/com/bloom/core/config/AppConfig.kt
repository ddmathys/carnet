package com.bloom.core.config

object AppConfig {
    // DeepSeek API key — from Flutter app
    const val DEEPSEEK_API_KEY = "sk-a0368a12392e4bf290f9fc3246dba045"

    // Claude API key — set your Anthropic API key here
    const val CLAUDE_API_KEY = ""

    // Firebase project — from android google-services.json
    const val FIREBASE_PROJECT_ID = "bloom-bcb1f"

    // Firebase Web API key — get from Firebase Console > Project Settings > General > Web API Key
    // This is required for Authentication REST API calls
    const val FIREBASE_WEB_API_KEY = "TODO_SET_FROM_FIREBASE_CONSOLE"
}
