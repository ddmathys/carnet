package com.bloom.core.models

import kotlinx.datetime.*

data class MilestoneModel(
    val id: String = "",
    val childId: String,
    val type: String,
    val subType: String? = null,
    val date: LocalDateTime,
    val datePrecision: String = "exact",
    val dateLabel: String? = null,
    val rawContent: String,
    val aiNarration: String? = null,
    val photoUrl: String? = null,
    val weightKg: Double? = null,
    val heightCm: Double? = null,
    val createdAt: LocalDateTime,
)
