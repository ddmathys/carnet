package com.bloom.features.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.di.ServiceLocator
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch

@Composable
fun AuthScreen() {
    val scope = rememberCoroutineScope()
    var isLogin by remember { mutableStateOf(true) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var resetSent by remember { mutableStateOf(false) }

    fun submit() {
        if (email.isBlank() || !email.contains("@")) { error = "Email invalide"; return }
        if (password.length < 6) { error = "6 caractères minimum"; return }
        scope.launch {
            loading = true; error = null
            val result = if (isLogin)
                ServiceLocator.authService.signIn(email, password)
            else
                ServiceLocator.authService.signUp(email, password)
            result.onSuccess { AppRouter.navigateAndClear(Screen.Home) }
                .onFailure { error = mapError(it.message ?: "") }
            loading = false
        }
    }

    fun sendReset() {
        if (email.isBlank() || !email.contains("@")) { error = "Saisis ton email d'abord."; return }
        scope.launch {
            loading = true
            ServiceLocator.authService.sendPasswordReset(email)
                .onSuccess { resetSent = true }
                .onFailure { error = "Une erreur est survenue." }
            loading = false
        }
    }

    Box(
        modifier = Modifier.fillMaxSize().background(AppColors.Beige),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 480.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
        ) {
            Spacer(Modifier.height(40.dp))
            Text("🌸", fontSize = 64.sp)
            Spacer(Modifier.height(16.dp))
            Text(
                text = if (isLogin) "Bon retour !" else "Créer un compte",
                style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = if (isLogin) "Retrouve les souvenirs de ton enfant."
                else "Commence à capturer les premiers instants.",
                color = AppColors.TextMedium,
            )
            Spacer(Modifier.height(32.dp))

            OutlinedTextField(
                value = email,
                onValueChange = { email = it; error = null },
                label = { Text("Email") },
                modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Email,
                    imeAction = ImeAction.Next,
                ),
                singleLine = true,
                colors = bloomTextFieldColors(),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = password,
                onValueChange = { password = it; error = null },
                label = { Text("Mot de passe") },
                modifier = Modifier.fillMaxWidth(),
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                singleLine = true,
                colors = bloomTextFieldColors(),
            )

            error?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = AppColors.Error, style = MaterialTheme.typography.bodySmall)
            }
            if (resetSent) {
                Spacer(Modifier.height(8.dp))
                Card(colors = CardDefaults.cardColors(containerColor = AppColors.Sage.copy(alpha = 0.1f))) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("✓", color = AppColors.Sage)
                        Spacer(Modifier.width(8.dp))
                        Text("Email envoyé ! Vérifie ta boîte mail.", color = AppColors.Sage, fontSize = 13.sp)
                    }
                }
            }
            Spacer(Modifier.height(20.dp))

            if (loading) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = AppColors.Sage)
                }
            } else {
                Button(
                    onClick = { submit() },
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                    shape = MaterialTheme.shapes.medium,
                ) {
                    Text(if (isLogin) "Se connecter" else "S'inscrire", fontWeight = FontWeight.Medium)
                }
            }

            if (isLogin) {
                TextButton(
                    onClick = { sendReset() },
                    enabled = !loading,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Mot de passe oublié ?", color = AppColors.Sage, fontSize = 13.sp)
                }
            }

            Spacer(Modifier.height(16.dp))
            Divider(color = AppColors.SoftGray.copy(alpha = 0.3f))
            Spacer(Modifier.height(16.dp))

            Text(
                text = if (isLogin) "Pas encore de compte ? S'inscrire"
                else "Déjà un compte ? Se connecter",
                color = AppColors.Sage,
                style = MaterialTheme.typography.bodyMedium.copy(
                    textDecoration = TextDecoration.Underline,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable {
                        isLogin = !isLogin; error = null; resetSent = false
                    }
                    .padding(8.dp),
            )
        }
    }
}

@Composable
private fun bloomTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = AppColors.Sage,
    unfocusedBorderColor = AppColors.SoftGray,
    focusedLabelColor = AppColors.Sage,
    cursorColor = AppColors.Sage,
)

private fun mapError(msg: String): String = when {
    "EMAIL_NOT_FOUND" in msg || "user-not-found" in msg -> "Aucun compte avec cet email."
    "INVALID_PASSWORD" in msg || "wrong-password" in msg -> "Mot de passe incorrect."
    "EMAIL_EXISTS" in msg || "email-already-in-use" in msg -> "Cet email est déjà utilisé."
    "WEAK_PASSWORD" in msg || "weak-password" in msg -> "Mot de passe trop faible (6 caractères min)."
    else -> "Une erreur est survenue. Réessaie."
}
