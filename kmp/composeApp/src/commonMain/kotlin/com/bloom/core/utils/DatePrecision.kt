package com.bloom.core.utils

import kotlinx.datetime.LocalDateTime

enum class DatePrecision { EXACT, MONTH, QUARTER }

private val FRENCH_MONTHS = arrayOf(
    "janvier", "février", "mars", "avril", "mai", "juin",
    "juillet", "août", "septembre", "octobre", "novembre", "décembre"
)

fun formatDateFr(date: LocalDateTime, precision: DatePrecision): String = when (precision) {
    DatePrecision.EXACT -> "${date.dayOfMonth} ${FRENCH_MONTHS[date.monthNumber - 1]} ${date.year}"
    DatePrecision.MONTH -> "${FRENCH_MONTHS[date.monthNumber - 1]} ${date.year}"
    DatePrecision.QUARTER -> {
        val q = (date.monthNumber - 1) / 3 + 1
        "T$q ${date.year}"
    }
}

fun datePrecisionFromString(s: String?): DatePrecision = when (s) {
    "month" -> DatePrecision.MONTH
    "quarter" -> DatePrecision.QUARTER
    else -> DatePrecision.EXACT
}

fun datePrecisionToString(p: DatePrecision): String = when (p) {
    DatePrecision.EXACT -> "exact"
    DatePrecision.MONTH -> "month"
    DatePrecision.QUARTER -> "quarter"
}
