package com.bloom.core.models

import com.bloom.core.constants.getMilestoneSubTypeById
import com.bloom.core.utils.DatePrecision
import com.bloom.core.utils.datePrecisionToString
import com.bloom.core.utils.formatDateFr
import kotlinx.datetime.*
import kotlin.math.pow

data class DraftMilestone(
    var type: String,
    var subType: String? = null,
    var date: LocalDateTime? = null,
    var datePrecision: DatePrecision = DatePrecision.EXACT,
    var rawContent: String = "",
    var weightKg: Double? = null,
    var heightCm: Double? = null,
    var included: Boolean = true,
) {
    val needsDate: Boolean get() = date == null

    val needsSubType: Boolean get() =
        (type == "parole" || type == "mouvement") && subType == null

    val isValid: Boolean
        get() {
            if (date == null) return false
            return when (type) {
                "parole", "mouvement" -> subType != null
                "taille_poids" -> (weightKg != null && weightKg!! > 0) ||
                        (heightCm != null && heightCm!! > 0)
                "anecdote" -> rawContent.trim().isNotEmpty()
                else -> true
            }
        }

    fun buildRawContent(): String = when (type) {
        "parole" -> {
            val subLabel = getMilestoneSubTypeById(type, subType ?: "")?.label ?: ""
            if (rawContent.isNotEmpty()) "$subLabel : \"$rawContent\"" else subLabel
        }
        "mouvement" -> {
            val subLabel = getMilestoneSubTypeById(type, subType ?: "")?.label ?: ""
            if (rawContent.isNotEmpty()) "$subLabel — $rawContent" else subLabel
        }
        "taille_poids" -> {
            val parts = mutableListOf<String>()
            weightKg?.let { parts.add("${it.toFixed(1)} kg") }
            heightCm?.let { parts.add("${it.toFixed(1)} cm") }
            parts.joinToString(" • ")
        }
        else -> rawContent.trim()
    }

    fun toMilestoneModel(childId: String): MilestoneModel {
        val now = Clock.System.now().toLocalDateTime(TimeZone.UTC)
        val d = date ?: now
        return MilestoneModel(
            childId = childId,
            type = type,
            subType = subType,
            date = d,
            datePrecision = datePrecisionToString(datePrecision),
            dateLabel = formatDateFr(d, datePrecision),
            rawContent = buildRawContent(),
            weightKg = weightKg,
            heightCm = heightCm,
            createdAt = now,
        )
    }
}

fun Double.toFixed(decimals: Int): String {
    val factor = 10.0.pow(decimals)
    val shifted = (this * factor).toLong()
    val intPart = shifted / factor.toLong()
    val decPart = shifted % factor.toLong()
    return if (decimals == 0) intPart.toString()
    else "$intPart.${decPart.toString().padStart(decimals, '0')}"
}
