package com.bloom.features.navigation

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

sealed class Screen {
    data object Splash : Screen()
    data object Auth : Screen()
    data object Home : Screen()
    data object AddChild : Screen()
    data class ChildTimeline(val childId: String) : Screen()
    data class AddMilestone(val childId: String, val milestoneId: String? = null) : Screen()
    data class Story(val childId: String) : Screen()
    data class Growth(val childId: String) : Screen()
    data class Summary(val childId: String) : Screen()
    data object Profile : Screen()
}

object AppRouter {
    private var _stack: List<Screen> by mutableStateOf(listOf(Screen.Splash))

    val current: Screen get() = _stack.last()
    val canGoBack: Boolean get() = _stack.size > 1

    fun navigate(screen: Screen) {
        _stack = _stack + screen
    }

    fun navigateAndClear(screen: Screen) {
        _stack = listOf(screen)
    }

    fun back() {
        if (_stack.size > 1) {
            _stack = _stack.dropLast(1)
        }
    }
}
