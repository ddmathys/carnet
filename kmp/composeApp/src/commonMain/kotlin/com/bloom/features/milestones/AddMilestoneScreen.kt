package com.bloom.features.milestones

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.*
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.DraftMilestone
import com.bloom.core.models.MilestoneModel
import com.bloom.core.theme.AppColors
import com.bloom.core.utils.DatePrecision
import com.bloom.core.utils.formatDateFr
import com.bloom.features.milestones.widgets.FlexibleDateSheet
import com.bloom.features.navigation.AppRouter
import kotlinx.coroutines.launch
import kotlinx.datetime.*

@Composable
fun AddMilestoneScreen(childId: String, milestoneId: String? = null) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(0) }
    var freeText by remember { mutableStateOf("") }
    var drafts by remember { mutableStateOf<List<DraftMilestone>>(emptyList()) }
    var extracting by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var existingMilestone by remember { mutableStateOf<MilestoneModel?>(null) }
    var showDatePicker by remember { mutableStateOf<Int?>(null) }

    // Load existing milestone for edit mode
    LaunchedEffect(milestoneId) {
        if (milestoneId == null) return@LaunchedEffect
        ServiceLocator.firestoreService.getMilestones(childId).onSuccess { list ->
            existingMilestone = list.firstOrNull { it.id == milestoneId }
            existingMilestone?.let { m ->
                freeText = m.rawContent
                drafts = listOf(
                    DraftMilestone(
                        type = m.type,
                        subType = m.subType,
                        date = m.date,
                        datePrecision = com.bloom.core.utils.datePrecisionFromString(m.datePrecision),
                        rawContent = m.rawContent,
                        weightKg = m.weightKg,
                        heightCm = m.heightCm,
                    )
                )
                step = 1
            }
        }
    }

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(if (milestoneId != null) "Modifier le souvenir" else "Nouveau souvenir", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = { if (step > 0 && milestoneId == null) step-- else AppRouter.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (step) {
                0 -> InputStep(
                    freeText = freeText,
                    onTextChange = { freeText = it },
                    extracting = extracting,
                    error = error,
                    onExtract = {
                        if (freeText.isBlank()) { error = "Écris quelque chose d'abord."; return@InputStep }
                        scope.launch {
                            extracting = true; error = null
                            val result = ServiceLocator.deepSeekService.extractAllMilestonesFromText(freeText)
                            if (result != null && result.isNotEmpty()) {
                                drafts = result
                                step = 1
                            } else {
                                // Fallback: create single draft
                                drafts = listOf(DraftMilestone(type = "anecdote", rawContent = freeText))
                                step = 1
                            }
                            extracting = false
                        }
                    },
                    onSkipAI = {
                        if (freeText.isBlank()) { error = "Écris quelque chose d'abord."; return@InputStep }
                        drafts = listOf(DraftMilestone(type = "anecdote", rawContent = freeText))
                        step = 1
                    },
                )
                1 -> ReviewStep(
                    drafts = drafts,
                    onDraftsChange = { drafts = it },
                    saving = saving,
                    error = error,
                    showDatePicker = showDatePicker,
                    onShowDatePicker = { showDatePicker = it },
                    onSave = {
                        val validDrafts = drafts.filter { it.included }
                        if (validDrafts.isEmpty()) { error = "Sélectionne au moins un souvenir."; return@ReviewStep }
                        val invalid = validDrafts.firstOrNull { it.date == null }
                        if (invalid != null) { error = "Définis la date pour tous les souvenirs sélectionnés."; return@ReviewStep }
                        scope.launch {
                            saving = true; error = null
                            if (milestoneId != null && existingMilestone != null) {
                                val m = validDrafts.first().toMilestoneModel(childId).copy(id = milestoneId)
                                ServiceLocator.firestoreService.updateMilestone(m)
                                    .onSuccess { AppRouter.back() }
                                    .onFailure { error = "Erreur lors de la sauvegarde." }
                            } else {
                                var success = true
                                for (draft in validDrafts) {
                                    val m = draft.toMilestoneModel(childId)
                                    ServiceLocator.firestoreService.addMilestone(m)
                                        .onFailure { success = false }
                                }
                                if (success) AppRouter.back()
                                else error = "Erreur lors de la sauvegarde."
                            }
                            saving = false
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun InputStep(
    freeText: String,
    onTextChange: (String) -> Unit,
    extracting: Boolean,
    error: String?,
    onExtract: () -> Unit,
    onSkipAI: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
    ) {
        Text("Raconte un souvenir", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
        Text("Décris librement ce qui s'est passé. L'IA va organiser le tout.", color = AppColors.TextMedium, fontSize = 14.sp)
        Spacer(Modifier.height(20.dp))

        OutlinedTextField(
            value = freeText,
            onValueChange = onTextChange,
            modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp),
            placeholder = { Text("Ex: Aujourd'hui Léa a fait ses premiers pas ! Elle a marché vers moi avec un grand sourire...") },
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
        )

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = AppColors.Error, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(24.dp))

        if (extracting) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = AppColors.Sage)
                    Spacer(Modifier.height(8.dp))
                    Text("Analyse en cours...", color = AppColors.TextMedium, fontSize = 13.sp)
                }
            }
        } else {
            Button(
                onClick = onExtract,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                shape = MaterialTheme.shapes.medium,
            ) {
                Text("✨ Analyser avec l'IA", fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(
                onClick = onSkipAI,
                modifier = Modifier.fillMaxWidth().height(48.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = AppColors.Sage),
            ) {
                Text("Continuer sans IA")
            }
        }
    }
}

@Composable
private fun ReviewStep(
    drafts: List<DraftMilestone>,
    onDraftsChange: (List<DraftMilestone>) -> Unit,
    saving: Boolean,
    error: String?,
    showDatePicker: Int?,
    onShowDatePicker: (Int?) -> Unit,
    onSave: () -> Unit,
) {
    val mutableDrafts = remember(drafts) { drafts.toMutableStateList() }

    LaunchedEffect(mutableDrafts.toList()) {
        onDraftsChange(mutableDrafts.toList())
    }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(
                    "${mutableDrafts.count { it.included }} souvenir(s) à enregistrer",
                    fontWeight = FontWeight.Bold,
                    color = AppColors.TextDark,
                )
            }
            items(mutableDrafts.indices.toList()) { i ->
                val draft = mutableDrafts[i]
                DraftCard(
                    draft = draft,
                    index = i,
                    onToggle = { mutableDrafts[i] = draft.copy(included = !draft.included) },
                    onTypeChange = { newType -> mutableDrafts[i] = draft.copy(type = newType, subType = null) },
                    onSubTypeChange = { st -> mutableDrafts[i] = draft.copy(subType = st) },
                    onContentChange = { txt -> mutableDrafts[i] = draft.copy(rawContent = txt) },
                    onWeightChange = { w -> mutableDrafts[i] = draft.copy(weightKg = w) },
                    onHeightChange = { h -> mutableDrafts[i] = draft.copy(heightCm = h) },
                    onPickDate = { onShowDatePicker(i) },
                )
            }
            error?.let {
                item {
                    Text(it, color = AppColors.Error, style = MaterialTheme.typography.bodySmall)
                }
            }
            item {
                if (saving) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = AppColors.Sage)
                    }
                } else {
                    Button(
                        onClick = onSave,
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        Text("💾 Enregistrer", fontWeight = FontWeight.Medium)
                    }
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }

    showDatePicker?.let { idx ->
        if (idx < drafts.size) {
            val draft = drafts[idx]
            Box(Modifier.fillMaxSize().background(AppColors.TextDark.copy(alpha = 0.5f)), contentAlignment = Alignment.BottomCenter) {
                FlexibleDateSheet(
                    initialDate = draft.date,
                    initialPrecision = draft.datePrecision,
                    onDismiss = { onShowDatePicker(null) },
                    onConfirm = { date, prec ->
                        val newDrafts = drafts.toMutableList()
                        newDrafts[idx] = draft.copy(date = date, datePrecision = prec)
                        onDraftsChange(newDrafts)
                        onShowDatePicker(null)
                    },
                )
            }
        }
    }
}

@Composable
private fun DraftCard(
    draft: DraftMilestone,
    index: Int,
    onToggle: () -> Unit,
    onTypeChange: (String) -> Unit,
    onSubTypeChange: (String) -> Unit,
    onContentChange: (String) -> Unit,
    onWeightChange: (Double?) -> Unit,
    onHeightChange: (Double?) -> Unit,
    onPickDate: () -> Unit,
) {
    val cat = getMilestoneCategoryById(draft.type)
    val dateStr = draft.date?.let { formatDateFr(it, draft.datePrecision) }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (draft.included) AppColors.White else AppColors.SoftGray.copy(alpha = 0.2f),
        ),
        elevation = CardDefaults.cardElevation(0.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(
                    checked = draft.included,
                    onCheckedChange = { onToggle() },
                    colors = CheckboxDefaults.colors(checkedColor = AppColors.Sage),
                )
                Text("${cat.emoji} ${cat.label}", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                TextButton(onClick = onPickDate) {
                    Text(dateStr ?: "📅 Date", color = if (dateStr != null) AppColors.Sage else AppColors.Error, fontSize = 13.sp)
                }
            }

            if (!draft.included) return@Card

            // Type selector (simplified - show dropdown button)
            if (draft.type != "taille_poids") {
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = draft.rawContent,
                    onValueChange = onContentChange,
                    label = { Text("Description") },
                    modifier = Modifier.fillMaxWidth(),
                    maxLines = 3,
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                )
            }

            if (draft.type == "taille_poids" || draft.type == "naissance") {
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = draft.weightKg?.toString() ?: "",
                        onValueChange = { onWeightChange(it.toDoubleOrNull()) },
                        label = { Text("Poids (kg)") },
                        modifier = Modifier.weight(1f),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                    OutlinedTextField(
                        value = draft.heightCm?.toString() ?: "",
                        onValueChange = { onHeightChange(it.toDoubleOrNull()) },
                        label = { Text("Taille (cm)") },
                        modifier = Modifier.weight(1f),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                }
            }

            // SubType selector for legacy types
            if (cat.subTypes.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text("Préciser :", fontSize = 12.sp, color = AppColors.TextMedium)
                cat.subTypes.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 2.dp)) {
                        row.forEach { sub ->
                            FilterChip(
                                selected = draft.subType == sub.id,
                                onClick = { onSubTypeChange(sub.id) },
                                label = { Text(sub.label, fontSize = 11.sp) },
                                modifier = Modifier.weight(1f),
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = AppColors.Sage,
                                    selectedLabelColor = AppColors.White,
                                ),
                            )
                        }
                    }
                }
            }
        }
    }
}
