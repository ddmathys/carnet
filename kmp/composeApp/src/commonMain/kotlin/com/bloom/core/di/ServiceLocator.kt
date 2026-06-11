package com.bloom.core.di

import com.bloom.core.config.AppConfig
import com.bloom.core.services.ClaudeService
import com.bloom.core.services.DeepSeekService
import com.bloom.core.services.FirebaseAuthService
import com.bloom.core.services.FirestoreService
import io.ktor.client.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.logging.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.json.Json

object ServiceLocator {
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    val httpClient: HttpClient by lazy {
        HttpClient {
            install(ContentNegotiation) {
                json(json)
            }
            install(Logging) {
                level = LogLevel.NONE
            }
        }
    }

    val authService: FirebaseAuthService by lazy {
        FirebaseAuthService(httpClient)
    }

    val firestoreService: FirestoreService by lazy {
        FirestoreService(httpClient, authService)
    }

    val deepSeekService: DeepSeekService by lazy {
        DeepSeekService(httpClient, AppConfig.DEEPSEEK_API_KEY)
    }

    val claudeService: ClaudeService by lazy {
        ClaudeService(httpClient, AppConfig.CLAUDE_API_KEY)
    }
}
