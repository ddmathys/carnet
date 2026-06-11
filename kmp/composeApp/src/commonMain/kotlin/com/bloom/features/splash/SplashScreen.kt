package com.bloom.features.splash

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.di.ServiceLocator
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.delay

@Composable
fun SplashScreen() {
    val alpha by rememberInfiniteTransition(label = "bloom_pulse").animateFloat(
        initialValue = 0.7f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(800, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "alpha",
    )

    LaunchedEffect(Unit) {
        delay(1000)
        if (ServiceLocator.authService.currentUser != null) {
            AppRouter.navigateAndClear(Screen.Home)
        } else {
            AppRouter.navigateAndClear(Screen.Auth)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppColors.Beige),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "🌸",
                fontSize = 72.sp,
                modifier = Modifier.alpha(alpha),
            )
            Spacer(Modifier.height(16.dp))
            Text(
                text = "Bloom",
                style = MaterialTheme.typography.headlineLarge.copy(
                    fontWeight = FontWeight.Bold,
                    color = AppColors.TextDark,
                    fontSize = 40.sp,
                ),
                modifier = Modifier.alpha(alpha),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Le journal de vie de ton enfant",
                style = MaterialTheme.typography.bodyMedium,
                color = AppColors.TextMedium,
            )
        }
    }
}
