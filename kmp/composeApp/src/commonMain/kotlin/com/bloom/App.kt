package com.bloom

import androidx.compose.runtime.*
import com.bloom.core.theme.AppTheme
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import com.bloom.features.auth.AuthScreen
import com.bloom.features.children.AddChildScreen
import com.bloom.features.children.ChildTimelineScreen
import com.bloom.features.children.HomeScreen
import com.bloom.features.children.SummaryScreen
import com.bloom.features.growth.GrowthScreen
import com.bloom.features.milestones.AddMilestoneScreen
import com.bloom.features.profile.ProfileScreen
import com.bloom.features.splash.SplashScreen
import com.bloom.features.story.StoryScreen

@Composable
fun App() {
    AppTheme {
        val currentScreen = AppRouter.current
        when (val screen = currentScreen) {
            is Screen.Splash -> SplashScreen()
            is Screen.Auth -> AuthScreen()
            is Screen.Home -> HomeScreen()
            is Screen.AddChild -> AddChildScreen()
            is Screen.ChildTimeline -> ChildTimelineScreen(screen.childId)
            is Screen.AddMilestone -> AddMilestoneScreen(screen.childId, screen.milestoneId)
            is Screen.Story -> StoryScreen(screen.childId)
            is Screen.Growth -> GrowthScreen(screen.childId)
            is Screen.Summary -> SummaryScreen(screen.childId)
            is Screen.Profile -> ProfileScreen()
        }
    }
}
