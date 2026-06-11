package com.bloom.features.children

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.getAnimalById
import com.bloom.core.constants.getMilestoneCategoryById
import com.bloom.core.constants.kMilestoneCategories
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.core.utils.datePrecisionFromString
import com.bloom.core.utils.formatDateFr
import com.bloom.features.navigation.AppRouter
import kotlinx.coroutines.launch

@Composable
fun SummaryScreen(childId: String) {
    val scope = rememberCoroutineScope()
    var child by remember { mutableStateOf<ChildModel?>(null) }
    var milestones by remember { mutableStateOf<List<MilestoneModel>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(childId) {
        scope.launch {
            val uid = ServiceLocator.authService.currentUser?.uid ?: return@launch
            ServiceLocator.firestoreService.getChildren(uid).onSuccess { list ->
                child = list.firstOrNull { it.id == childId }
            }
            ServiceLocator.firestoreService.getMilestones(childId).onSuccess { ms ->
                milestones = ms
            }
            loading = false
        }
    }

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Résumé", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = { AppRouter.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
    ) { padding ->
        if (loading) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppColors.Sage)
            }
            return@Scaffold
        }

        val c = child ?: return@Scaffold
        val animal = getAnimalById(c.animalId)
        val latestWeight = milestones.filter { it.weightKg != null }.maxByOrNull { it.date }
        val latestHeight = milestones.filter { it.heightCm != null }.maxByOrNull { it.date }
        val byCategory = kMilestoneCategories.associate { cat ->
            cat.id to milestones.count { it.type == cat.id }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                // Header card
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(20.dp),
                    colors = CardDefaults.cardColors(containerColor = c.coverColor.hexToColor().copy(alpha = 0.15f)),
                ) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(animal.emoji, fontSize = 48.sp)
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(c.firstName, style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
                            Text(c.age, color = AppColors.TextMedium)
                            Text("${milestones.size} souvenirs", color = AppColors.Sage, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }

            if (latestWeight != null || latestHeight != null) {
                item {
                    Text("Mesures", fontWeight = FontWeight.Bold, fontSize = 16.sp, color = AppColors.TextDark)
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        latestWeight?.let { m ->
                            val dateStr = formatDateFr(m.date, datePrecisionFromString(m.datePrecision))
                            StatCard("⚖️", "Poids", "${m.weightKg} kg", dateStr, Modifier.weight(1f))
                        }
                        latestHeight?.let { m ->
                            val dateStr = formatDateFr(m.date, datePrecisionFromString(m.datePrecision))
                            StatCard("📏", "Taille", "${m.heightCm} cm", dateStr, Modifier.weight(1f))
                        }
                    }
                }
            }

            item {
                Text("Souvenirs par catégorie", fontWeight = FontWeight.Bold, fontSize = 16.sp, color = AppColors.TextDark)
            }

            items(kMilestoneCategories.filter { !it.isLegacy }) { cat ->
                val count = byCategory[cat.id] ?: 0
                if (count > 0) {
                    Row(
                        Modifier.fillMaxWidth().background(AppColors.White, RoundedCornerShape(12.dp)).padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(cat.emoji, fontSize = 20.sp)
                        Spacer(Modifier.width(12.dp))
                        Text(cat.label, Modifier.weight(1f), color = AppColors.TextDark)
                        Text("$count", fontWeight = FontWeight.Bold, color = AppColors.Sage)
                    }
                }
            }

            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun StatCard(emoji: String, label: String, value: String, date: String, modifier: Modifier) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White),
        elevation = CardDefaults.cardElevation(0.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(emoji, fontSize = 24.sp)
            Spacer(Modifier.height(4.dp))
            Text(label, fontSize = 12.sp, color = AppColors.TextMedium)
            Text(value, fontWeight = FontWeight.Bold, color = AppColors.TextDark)
            Text(date, fontSize = 11.sp, color = AppColors.SoftGray)
        }
    }
}
