package com.bloom.features.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.di.ServiceLocator
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch

@Composable
fun ProfileScreen() {
    val scope = rememberCoroutineScope()
    val user = ServiceLocator.authService.currentUser
    var displayName by remember { mutableStateOf(user?.displayName ?: "") }
    var editingName by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Profil", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = { AppRouter.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(24.dp))

            // Avatar
            Box(
                modifier = Modifier.size(80.dp).clip(CircleShape).background(AppColors.Sage.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    (user?.displayName?.firstOrNull() ?: user?.email?.firstOrNull() ?: '?')
                        .uppercaseChar().toString(),
                    fontSize = 36.sp,
                    color = AppColors.Sage,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.height(16.dp))

            Text(
                user?.email ?: "",
                style = MaterialTheme.typography.bodyMedium,
                color = AppColors.TextMedium,
            )
            Spacer(Modifier.height(32.dp))

            // Display name
            if (editingName) {
                OutlinedTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    label = { Text("Nom affiché") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                )
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = { editingName = false },
                        modifier = Modifier.weight(1f),
                    ) { Text("Annuler") }
                    Button(
                        onClick = {
                            scope.launch {
                                loading = true
                                ServiceLocator.authService.updateDisplayName(displayName)
                                    .onSuccess { message = "Nom mis à jour !" }
                                    .onFailure { message = "Erreur lors de la mise à jour." }
                                loading = false
                                editingName = false
                            }
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                        enabled = !loading,
                    ) {
                        if (loading) CircularProgressIndicator(Modifier.size(16.dp), color = AppColors.White, strokeWidth = 2.dp)
                        else Text("Enregistrer")
                    }
                }
            } else {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Nom affiché", fontSize = 12.sp, color = AppColors.TextMedium)
                        Text(
                            if (displayName.isBlank()) "Non défini" else displayName,
                            fontWeight = FontWeight.Medium,
                            color = if (displayName.isBlank()) AppColors.SoftGray else AppColors.TextDark,
                        )
                    }
                    TextButton(onClick = { editingName = true }) {
                        Text("Modifier", color = AppColors.Sage)
                    }
                }
            }

            message?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = AppColors.Sage, fontSize = 13.sp)
            }

            Spacer(Modifier.weight(1f))

            Divider(color = AppColors.SoftGray.copy(alpha = 0.3f))
            Spacer(Modifier.height(16.dp))

            Button(
                onClick = {
                    ServiceLocator.authService.signOut()
                    AppRouter.navigateAndClear(Screen.Auth)
                },
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = AppColors.Error),
                shape = MaterialTheme.shapes.medium,
            ) {
                Text("Se déconnecter", fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}
