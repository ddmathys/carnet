package com.bloom.features.children

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.getMilestoneCategoryById
import com.bloom.core.constants.kMilestoneCategories
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.core.utils.formatDateFr
import com.bloom.core.utils.datePrecisionFromString
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch

@Composable
fun ChildTimelineScreen(childId: String) {
    val scope = rememberCoroutineScope()
    var child by remember { mutableStateOf<ChildModel?>(null) }
    var milestones by remember { mutableStateOf<List<MilestoneModel>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var filterType by remember { mutableStateOf<String?>(null) }
    var filterYear by remember { mutableStateOf<Int?>(null) }

    fun load() {
        scope.launch {
            loading = true
            val uid = ServiceLocator.authService.currentUser?.uid ?: return@launch
            ServiceLocator.firestoreService.getChildren(uid).onSuccess { list ->
                child = list.firstOrNull { it.id == childId }
            }
            ServiceLocator.firestoreService.getMilestones(childId).onSuccess { list ->
                milestones = list
            }
            loading = false
        }
    }

    LaunchedEffect(childId) { load() }

    val filtered = milestones.filter { m ->
        (filterType == null || m.type == filterType) &&
        (filterYear == null || m.date.year == filterYear)
    }

    val years = milestones.map { it.date.year }.distinct().sortedDescending()

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(child?.firstName ?: "...", fontWeight = FontWeight.Bold)
                        child?.age?.let { Text(it, fontSize = 12.sp, color = AppColors.TextMedium) }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = { AppRouter.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
                    }
                },
                actions = {
                    TextButton(onClick = { child?.let { AppRouter.navigate(Screen.Summary(childId)) } }) {
                        Text("Résumé", color = AppColors.Sage, fontSize = 13.sp)
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { AppRouter.navigate(Screen.AddMilestone(childId)) },
                containerColor = AppColors.Sage,
                contentColor = AppColors.White,
            ) {
                Icon(Icons.Default.Add, "Ajouter un souvenir")
            }
        },
        bottomBar = {
            Row(
                Modifier.fillMaxWidth().background(AppColors.Cream).padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TextButton(onClick = { AppRouter.navigate(Screen.Growth(childId)) }) {
                    Text("📊 Croissance", color = AppColors.Sage, fontSize = 12.sp)
                }
                TextButton(onClick = { AppRouter.navigate(Screen.Story(childId)) }) {
                    Text("📖 Histoire", color = AppColors.Sage, fontSize = 12.sp)
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            // Filter bar
            if (years.isNotEmpty() || true) {
                ScrollableTypeFilter(
                    filterType = filterType,
                    onTypeChange = { filterType = it },
                )
            }

            Box(Modifier.weight(1f)) {
                when {
                    loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = AppColors.Sage)
                    }
                    filtered.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            if (filterType != null) "Aucun souvenir dans cette catégorie."
                            else "Aucun souvenir encore.\nAppuie sur + pour commencer !",
                            color = AppColors.TextMedium,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    else -> LazyColumn(
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        items(filtered, key = { it.id }) { milestone ->
                            MilestoneCard(
                                milestone = milestone,
                                onClick = { AppRouter.navigate(Screen.AddMilestone(childId, milestone.id)) },
                            )
                        }
                        item { Spacer(Modifier.height(80.dp)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScrollableTypeFilter(filterType: String?, onTypeChange: (String?) -> Unit) {
    val categories = listOf(null) + kMilestoneCategories.filter { !it.isLegacy }.map { it.id }
    androidx.compose.foundation.lazy.LazyRow(
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(categories) { typeId ->
            val isSelected = filterType == typeId
            val label = if (typeId == null) "Tous" else {
                val cat = getMilestoneCategoryById(typeId)
                "${cat.emoji} ${cat.label}"
            }
            FilterChip(
                selected = isSelected,
                onClick = { onTypeChange(typeId) },
                label = { Text(label, fontSize = 12.sp) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = AppColors.Sage,
                    selectedLabelColor = AppColors.White,
                ),
            )
        }
    }
}

@Composable
private fun MilestoneCard(milestone: MilestoneModel, onClick: () -> Unit) {
    val cat = getMilestoneCategoryById(milestone.type)
    val dateStr = milestone.dateLabel
        ?: formatDateFr(milestone.date, datePrecisionFromString(milestone.datePrecision))

    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White),
        elevation = CardDefaults.cardElevation(0.dp),
    ) {
        Row(Modifier.padding(16.dp)) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(AppColors.Beige, RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(cat.emoji, fontSize = 22.sp)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(cat.label, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = AppColors.TextDark)
                Text(dateStr, fontSize = 12.sp, color = AppColors.TextMedium)
                if (milestone.rawContent.isNotEmpty()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        milestone.rawContent,
                        fontSize = 13.sp,
                        color = AppColors.TextMedium,
                        maxLines = 2,
                    )
                }
            }
        }
    }
}
