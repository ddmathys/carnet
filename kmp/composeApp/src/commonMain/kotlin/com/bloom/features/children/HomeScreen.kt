package com.bloom.features.children

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.getAnimalById
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch
import kotlinx.datetime.*

@Composable
fun HomeScreen() {
    val scope = rememberCoroutineScope()
    var children by remember { mutableStateOf<List<ChildModel>>(emptyList()) }
    var lastMilestones by remember { mutableStateOf<Map<String, MilestoneModel?>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    var deleteCandidate by remember { mutableStateOf<ChildModel?>(null) }

    fun load() {
        val uid = ServiceLocator.authService.currentUser?.uid ?: return
        scope.launch {
            loading = true
            ServiceLocator.firestoreService.getChildren(uid).onSuccess { list ->
                children = list
                val map = mutableMapOf<String, MilestoneModel?>()
                list.forEach { child ->
                    ServiceLocator.firestoreService.getMilestones(child.id).onSuccess { ms ->
                        map[child.id] = ms.maxByOrNull { it.date }
                    }
                }
                lastMilestones = map
            }
            loading = false
        }
    }

    LaunchedEffect(Unit) { load() }

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "🌸 Bloom",
                        style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                    )
                },
                actions = {
                    IconButton(onClick = { AppRouter.navigate(Screen.Profile) }) {
                        Icon(Icons.Default.Person, contentDescription = "Profil", tint = AppColors.TextDark)
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { AppRouter.navigate(Screen.AddChild) },
                containerColor = AppColors.Sage,
                contentColor = AppColors.White,
            ) {
                Icon(Icons.Default.Add, contentDescription = "Ajouter un enfant")
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = AppColors.Sage)
                }
                children.isEmpty() -> EmptyHomeState()
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(children, key = { it.id }) { child ->
                        ChildCard(
                            child = child,
                            lastMilestone = lastMilestones[child.id],
                            onClick = { AppRouter.navigate(Screen.ChildTimeline(child.id)) },
                            onLongClick = { deleteCandidate = child },
                        )
                    }
                    item { Spacer(Modifier.height(72.dp)) }
                }
            }
        }
    }

    deleteCandidate?.let { child ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text("Supprimer ${child.firstName} ?") },
            text = { Text("Tous les souvenirs seront supprimés. Cette action est irréversible.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            ServiceLocator.firestoreService.deleteChild(child.id)
                            load()
                        }
                        deleteCandidate = null
                    },
                ) { Text("Supprimer", color = AppColors.Error) }
            },
            dismissButton = {
                TextButton(onClick = { deleteCandidate = null }) { Text("Annuler") }
            },
        )
    }
}

@Composable
private fun ChildCard(
    child: ChildModel,
    lastMilestone: MilestoneModel?,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val animal = getAnimalById(child.animalId)
    val cardColor = child.coverColor.hexToColor()
    val daysSinceLast = lastMilestone?.let {
        val now = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault())
        val d = (now.year - it.date.year) * 365 + (now.monthNumber - it.date.monthNumber) * 30 + (now.dayOfMonth - it.date.dayOfMonth)
        d
    }
    val dotColor = when {
        daysSinceLast == null -> AppColors.SoftGray
        daysSinceLast <= 7 -> Color(0xFF4CAF50)
        daysSinceLast <= 30 -> Color(0xFFFF9800)
        else -> AppColors.Error
    }

    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(cardColor.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(animal.emoji, fontSize = 32.sp)
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    child.firstName,
                    style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                )
                Text(child.age, color = AppColors.TextMedium, fontSize = 13.sp)
                Text("${animal.emoji} ${animal.name}", color = AppColors.TextMedium, fontSize = 12.sp)
            }
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(dotColor),
            )
        }
    }
}

@Composable
private fun EmptyHomeState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
            Text("🌱", fontSize = 64.sp)
            Spacer(Modifier.height(16.dp))
            Text(
                "Commence le journal",
                style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Appuie sur + pour ajouter ton premier enfant\net commencer à capturer ses souvenirs.",
                color = AppColors.TextMedium,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

fun String.hexToColor(): Color {
    val hex = removePrefix("#")
    return try {
        val value = hex.toLong(16)
        Color(
            red = ((value shr 16) and 0xFF) / 255f,
            green = ((value shr 8) and 0xFF) / 255f,
            blue = (value and 0xFF) / 255f,
            alpha = 1f,
        )
    } catch (_: Exception) { AppColors.Sage }
}
