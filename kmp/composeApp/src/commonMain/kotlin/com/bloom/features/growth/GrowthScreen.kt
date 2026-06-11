package com.bloom.features.growth

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
import com.bloom.core.data.getGrowthData
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.core.utils.datePrecisionFromString
import com.bloom.core.utils.formatDateFr
import com.bloom.features.milestones.widgets.GrowthCurveChart
import com.bloom.features.milestones.widgets.MeasurementPoint
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch

@Composable
fun GrowthScreen(childId: String) {
    val scope = rememberCoroutineScope()
    var child by remember { mutableStateOf<ChildModel?>(null) }
    var milestones by remember { mutableStateOf<List<MilestoneModel>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var selectedTab by remember { mutableStateOf(0) }

    LaunchedEffect(childId) {
        val uid = ServiceLocator.authService.currentUser?.uid ?: return@LaunchedEffect
        ServiceLocator.firestoreService.getChildren(uid).onSuccess { list ->
            child = list.firstOrNull { it.id == childId }
        }
        ServiceLocator.firestoreService.getMilestones(childId).onSuccess { ms ->
            milestones = ms
        }
        loading = false
    }

    val weightMeasurements = milestones.filter { it.weightKg != null }.sortedBy { it.date }
    val heightMeasurements = milestones.filter { it.heightCm != null }.sortedBy { it.date }
    val c = child

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Croissance", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = { AppRouter.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
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
                Icon(Icons.Default.Add, "Ajouter une mesure")
            }
        },
    ) { padding ->
        if (loading || c == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppColors.Sage)
            }
            return@Scaffold
        }

        Column(Modifier.fillMaxSize().padding(padding)) {
            TabRow(
                selectedTabIndex = selectedTab,
                containerColor = AppColors.Cream,
                contentColor = AppColors.Sage,
            ) {
                Tab(selected = selectedTab == 0, onClick = { selectedTab = 0 }, text = { Text("Courbes") })
                Tab(selected = selectedTab == 1, onClick = { selectedTab = 1 }, text = { Text("Mesures") })
            }

            when (selectedTab) {
                0 -> CurvesTab(c = c, weightMeasurements = weightMeasurements, heightMeasurements = heightMeasurements)
                1 -> MeasuresTab(weightMeasurements = weightMeasurements, heightMeasurements = heightMeasurements)
            }
        }
    }
}

@Composable
private fun CurvesTab(
    c: ChildModel,
    weightMeasurements: List<MilestoneModel>,
    heightMeasurements: List<MilestoneModel>,
) {
    var showWeight by remember { mutableStateOf(true) }

    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = showWeight,
                    onClick = { showWeight = true },
                    label = { Text("⚖️ Poids") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = AppColors.Sage,
                        selectedLabelColor = AppColors.White,
                    ),
                )
                FilterChip(
                    selected = !showWeight,
                    onClick = { showWeight = false },
                    label = { Text("📏 Taille") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = AppColors.Sage,
                        selectedLabelColor = AppColors.White,
                    ),
                )
            }
        }

        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = AppColors.White),
            ) {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        if (showWeight) "Poids (kg)" else "Taille (cm)",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        color = AppColors.TextDark,
                    )
                    Text("Courbes OMS 2006", fontSize = 11.sp, color = AppColors.TextMedium)
                    Spacer(Modifier.height(8.dp))

                    val refData = getGrowthData(c.gender, isWeight = showWeight)
                    val childPoints = if (showWeight) {
                        weightMeasurements.mapNotNull { m ->
                            m.weightKg?.let { MeasurementPoint(c.ageInMonths.coerceAtLeast(0), it) }
                        }
                    } else {
                        heightMeasurements.mapNotNull { m ->
                            m.heightCm?.let { MeasurementPoint(c.ageInMonths.coerceAtLeast(0), it) }
                        }
                    }

                    GrowthCurveChart(
                        referenceData = refData,
                        childPoints = childPoints,
                        isWeight = showWeight,
                    )
                    Spacer(Modifier.height(8.dp))

                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        LegendItem("─ p50", AppColors.Sage)
                        LegendItem("─ p3/p97", AppColors.Sage.copy(alpha = 0.5f))
                        LegendItem("─ Enfant", AppColors.Earth)
                    }
                }
            }
        }
        item { Spacer(Modifier.height(72.dp)) }
    }
}

@Composable
private fun LegendItem(label: String, color: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Divider(modifier = Modifier.width(16.dp), color = color, thickness = 2.dp)
        Spacer(Modifier.width(4.dp))
        Text(label, fontSize = 10.sp, color = AppColors.TextMedium)
    }
}

@Composable
private fun MeasuresTab(
    weightMeasurements: List<MilestoneModel>,
    heightMeasurements: List<MilestoneModel>,
) {
    val all = (weightMeasurements + heightMeasurements).distinctBy { it.id }.sortedByDescending { it.date }

    if (all.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("📊", fontSize = 48.sp)
                Spacer(Modifier.height(8.dp))
                Text("Aucune mesure enregistrée", color = AppColors.TextMedium)
            }
        }
        return
    }

    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(all, key = { it.id }) { m ->
            val dateStr = m.dateLabel ?: formatDateFr(m.date, datePrecisionFromString(m.datePrecision))
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = AppColors.White),
                elevation = CardDefaults.cardElevation(0.dp),
            ) {
                Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("📊", fontSize = 20.sp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(dateStr, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                        val parts = listOfNotNull(
                            m.weightKg?.let { "⚖️ $it kg" },
                            m.heightCm?.let { "📏 $it cm" },
                        )
                        Text(parts.joinToString("  "), color = AppColors.TextMedium, fontSize = 13.sp)
                    }
                }
            }
        }
        item { Spacer(Modifier.height(80.dp)) }
    }
}
