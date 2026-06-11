package com.bloom.features.story

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.getAnimalById
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import kotlinx.coroutines.launch

@Composable
fun StoryScreen(childId: String) {
    val scope = rememberCoroutineScope()
    var child by remember { mutableStateOf<ChildModel?>(null) }
    var milestones by remember { mutableStateOf<List<MilestoneModel>>(emptyList()) }
    var story by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var loadingData by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(childId) {
        val uid = ServiceLocator.authService.currentUser?.uid ?: return@LaunchedEffect
        ServiceLocator.firestoreService.getChildren(uid).onSuccess { list ->
            child = list.firstOrNull { it.id == childId }
        }
        ServiceLocator.firestoreService.getMilestones(childId).onSuccess { ms ->
            milestones = ms
        }
        loadingData = false
    }

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("L'histoire", fontWeight = FontWeight.Bold) },
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
            val c = child
            if (loadingData || c == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = AppColors.Sage)
                }
                return@Scaffold
            }

            val animal = getAnimalById(c.animalId)

            if (story == null) {
                Spacer(Modifier.weight(1f))
                Text(animal.emoji, fontSize = 80.sp)
                Spacer(Modifier.height(16.dp))
                Text(
                    "L'histoire de ${c.firstName}",
                    style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Avec ${animal.name} ${c.animalName} comme compagnon",
                    color = AppColors.TextMedium,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "${milestones.size} souvenirs seront tissés dans l'histoire",
                    fontSize = 13.sp,
                    color = AppColors.SoftGray,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(32.dp))
                error?.let {
                    Text(it, color = AppColors.Error, fontSize = 13.sp, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(12.dp))
                }
                if (loading) {
                    CircularProgressIndicator(color = AppColors.Sage)
                    Spacer(Modifier.height(8.dp))
                    Text("Génération en cours... (30-60s)", fontSize = 12.sp, color = AppColors.TextMedium)
                } else {
                    Button(
                        onClick = {
                            scope.launch {
                                loading = true; error = null
                                val result = ServiceLocator.deepSeekService.generateStory(
                                    childName = c.firstName,
                                    gender = c.gender,
                                    birthDate = c.birthDate,
                                    animalName = c.animalName,
                                    animalType = animal.name,
                                    animalEmoji = animal.emoji,
                                    animalTraits = animal.storyTraits,
                                    milestones = milestones,
                                )
                                if (result != null) story = result
                                else error = "Impossible de générer l'histoire. Vérifie ta connexion."
                                loading = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        Text("✨ Générer l'histoire", fontWeight = FontWeight.Medium)
                    }
                }
                Spacer(Modifier.weight(1f))
            } else {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(
                        "L'histoire de ${c.firstName}",
                        style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        "avec ${animal.emoji} ${c.animalName}",
                        color = AppColors.TextMedium,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(24.dp))

                    story!!.split("\n\n").forEach { paragraph ->
                        if (paragraph.isNotBlank()) {
                            Text(
                                paragraph.trim(),
                                style = MaterialTheme.typography.bodyLarge.copy(
                                    lineHeight = 26.sp,
                                    color = AppColors.TextDark,
                                ),
                                textAlign = TextAlign.Justify,
                            )
                            Spacer(Modifier.height(16.dp))
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    OutlinedButton(
                        onClick = { story = null },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = AppColors.Sage),
                    ) {
                        Text("Regénérer")
                    }
                    Spacer(Modifier.height(40.dp))
                }
            }
        }
    }
}
