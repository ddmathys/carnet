package com.bloom.core.models

import com.bloom.core.utils.DatePrecision
import kotlinx.datetime.LocalDateTime

data class ExtractedMilestone(
    val type: String,
    val subType: String? = null,
    val date: LocalDateTime? = null,
    val datePrecision: DatePrecision = DatePrecision.EXACT,
    val rawContent: String,
    val weightKg: Double? = null,
    val heightCm: Double? = null,
)
