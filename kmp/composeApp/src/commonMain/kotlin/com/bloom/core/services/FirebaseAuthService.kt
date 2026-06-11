package com.bloom.core.services

import com.bloom.core.config.AppConfig
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.http.*
import kotlinx.serialization.json.*

data class AuthUser(
    val uid: String,
    val email: String,
    val idToken: String,
    val refreshToken: String,
    val displayName: String = "",
)

class FirebaseAuthService(private val client: HttpClient) {
    private val base = "https://identitytoolkit.googleapis.com/v1/accounts"
    private val key = AppConfig.FIREBASE_WEB_API_KEY

    private var _currentUser: AuthUser? = null
    val currentUser: AuthUser? get() = _currentUser

    suspend fun signIn(email: String, password: String): Result<AuthUser> = runCatching {
        val body = client.post("$base:signInWithPassword?key=$key") {
            contentType(ContentType.Application.Json)
            setBody("""{"email":"$email","password":"$password","returnSecureToken":true}""")
        }.body<JsonObject>()
        val user = body.toAuthUser(email)
        _currentUser = user
        user
    }

    suspend fun signUp(email: String, password: String): Result<AuthUser> = runCatching {
        val body = client.post("$base:signUp?key=$key") {
            contentType(ContentType.Application.Json)
            setBody("""{"email":"$email","password":"$password","returnSecureToken":true}""")
        }.body<JsonObject>()
        val user = body.toAuthUser(email)
        _currentUser = user
        user
    }

    suspend fun sendPasswordReset(email: String): Result<Unit> = runCatching {
        client.post("$base:sendOobCode?key=$key") {
            contentType(ContentType.Application.Json)
            setBody("""{"requestType":"PASSWORD_RESET","email":"$email"}""")
        }
        Unit
    }

    suspend fun updateDisplayName(displayName: String): Result<Unit> = runCatching {
        val token = _currentUser?.idToken ?: return Result.failure(Exception("Not authenticated"))
        client.post("$base:update?key=$key") {
            contentType(ContentType.Application.Json)
            setBody("""{"idToken":"$token","displayName":"$displayName","returnSecureToken":false}""")
        }
        _currentUser = _currentUser?.copy(displayName = displayName)
        Unit
    }

    suspend fun refreshToken(): Boolean {
        val user = _currentUser ?: return false
        return runCatching {
            val body = client.post("https://securetoken.googleapis.com/v1/token?key=$key") {
                contentType(ContentType.Application.Json)
                setBody("""{"grant_type":"refresh_token","refresh_token":"${user.refreshToken}"}""")
            }.body<JsonObject>()
            _currentUser = user.copy(
                idToken = body["id_token"]?.jsonPrimitive?.content ?: user.idToken,
                refreshToken = body["refresh_token"]?.jsonPrimitive?.content ?: user.refreshToken,
            )
            true
        }.getOrDefault(false)
    }

    fun signOut() { _currentUser = null }

    private fun JsonObject.toAuthUser(fallbackEmail: String) = AuthUser(
        uid = this["localId"]?.jsonPrimitive?.content ?: "",
        email = this["email"]?.jsonPrimitive?.content ?: fallbackEmail,
        idToken = this["idToken"]?.jsonPrimitive?.content ?: "",
        refreshToken = this["refreshToken"]?.jsonPrimitive?.content ?: "",
        displayName = this["displayName"]?.jsonPrimitive?.content ?: "",
    )
}
