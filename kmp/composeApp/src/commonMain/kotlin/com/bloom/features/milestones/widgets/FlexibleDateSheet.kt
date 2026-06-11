package com.bloom.features.milestones.widgets

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.bloom.core.theme.AppColors
import com.bloom.core.utils.DatePrecision
import kotlinx.datetime.LocalDateTime

@Composable
fun FlexibleDateSheet(
    initialDate: LocalDateTime?,
    initialPrecision: DatePrecision,
    onDismiss: () -> Unit,
    onConfirm: (LocalDateTime, DatePrecision) -> Unit,
) {
    var precision by remember { mutableStateOf(initialPrecision) }
    var dayInput by remember { mutableStateOf(initialDate?.dayOfMonth?.toString() ?: "") }
    var monthInput by remember { mutableStateOf(initialDate?.monthNumber?.toString() ?: "") }
    var yearInput by remember { mutableStateOf(initialDate?.year?.toString() ?: "") }
    var quarterInput by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White),
    ) {
        Column(Modifier.padding(24.dp)) {
            Text("Quelle est la date ?", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
            Spacer(Modifier.height(16.dp))

            // Precision selector
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(DatePrecision.EXACT to "Exacte", DatePrecision.MONTH to "Mois", DatePrecision.QUARTER to "Trimestre").forEach { (p, label) ->
                    FilterChip(
                        selected = precision == p,
                        onClick = { precision = p; error = null },
                        label = { Text(label) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = AppColors.Sage,
                            selectedLabelColor = AppColors.White,
                        ),
                    )
                }
            }
            Spacer(Modifier.height(16.dp))

            when (precision) {
                DatePrecision.EXACT -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = dayInput, onValueChange = { dayInput = it },
                        label = { Text("Jour") }, modifier = Modifier.weight(1f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                    OutlinedTextField(
                        value = monthInput, onValueChange = { monthInput = it },
                        label = { Text("Mois") }, modifier = Modifier.weight(1f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                    OutlinedTextField(
                        value = yearInput, onValueChange = { yearInput = it },
                        label = { Text("Année") }, modifier = Modifier.weight(1.5f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                }
                DatePrecision.MONTH -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = monthInput, onValueChange = { monthInput = it },
                        label = { Text("Mois (1-12)") }, modifier = Modifier.weight(1f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                    OutlinedTextField(
                        value = yearInput, onValueChange = { yearInput = it },
                        label = { Text("Année") }, modifier = Modifier.weight(1.5f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                }
                DatePrecision.QUARTER -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = quarterInput, onValueChange = { quarterInput = it },
                        label = { Text("Trimestre (1-4)") }, modifier = Modifier.weight(1f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                    OutlinedTextField(
                        value = yearInput, onValueChange = { yearInput = it },
                        label = { Text("Année") }, modifier = Modifier.weight(1.5f), singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
                    )
                }
            }

            error?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = AppColors.Error, style = MaterialTheme.typography.bodySmall)
            }
            Spacer(Modifier.height(20.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text("Annuler") }
                Button(
                    onClick = {
                        val date = buildDate(precision, dayInput, monthInput, yearInput, quarterInput)
                        if (date == null) { error = "Date invalide"; return@Button }
                        onConfirm(date, precision)
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                ) { Text("Confirmer") }
            }
        }
    }
}

private fun buildDate(
    precision: DatePrecision,
    day: String, month: String, year: String, quarter: String,
): LocalDateTime? = try {
    when (precision) {
        DatePrecision.EXACT -> LocalDateTime(year.toInt(), month.toInt(), day.toInt(), 0, 0)
        DatePrecision.MONTH -> LocalDateTime(year.toInt(), month.toInt(), 1, 0, 0)
        DatePrecision.QUARTER -> {
            val q = quarter.toInt().coerceIn(1, 4)
            LocalDateTime(year.toInt(), (q - 1) * 3 + 1, 1, 0, 0)
        }
    }
} catch (_: Exception) { null }
