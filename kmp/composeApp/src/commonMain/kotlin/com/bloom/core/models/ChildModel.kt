package com.bloom.core.models

import kotlinx.datetime.*

data class ChildModel(
    val id: String = "",
    val parentId: String,
    val firstName: String,
    val birthDate: LocalDateTime,
    val animalId: String,
    val animalName: String,
    val coverColor: String,
    val gender: String,  // "boy" | "girl"
) {
    val ageInMonths: Int
        get() {
            val now = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault())
            return (now.year - birthDate.year) * 12 + now.monthNumber - birthDate.monthNumber
        }

    val age: String
        get() {
            val months = ageInMonths
            if (months < 12) return "$months mois"
            val years = months / 12
            val remaining = months % 12
            return if (remaining == 0) "$years an${if (years > 1) "s" else ""}"
            else "$years an${if (years > 1) "s" else ""} et $remaining mois"
        }
}
