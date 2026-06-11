package com.bloom.core.services

import com.bloom.core.constants.getMilestoneCategoryById
import com.bloom.core.constants.getMilestoneSubTypeById
import com.bloom.core.models.MilestoneModel
import com.bloom.core.utils.datePrecisionFromString
import com.bloom.core.utils.formatDateFr
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.http.*
import kotlinx.datetime.*
import kotlinx.serialization.json.*

class ClaudeService(private val client: HttpClient, private val apiKey: String) {
    private val apiUrl = "https://api.anthropic.com/v1/messages"

    suspend fun generateNarration(
        childName: String,
        birthDate: String,
        animalName: String,
        animalType: String,
        milestoneDate: String,
        rawContent: String,
    ): String? {
        val prompt = """Tu es le narrateur de Bloom, un journal de vie pour enfants.
Transforme cette note brute en un passage littéraire chaleureux (3 à 5 phrases max).
Écris à la 3e personne, intègre $animalName le $animalType naturellement dans la scène.
Ton : tendre, poétique, intemporel. Langue : français.

Enfant : $childName, né(e) le $birthDate
Note : $rawContent
Date : $milestoneDate

Génère uniquement le texte narratif."""
        return call(prompt, maxTokens = 300)
    }

    suspend fun generateStory(
        childName: String,
        gender: String,
        birthDate: LocalDateTime,
        animalName: String,
        animalType: String,
        animalEmoji: String,
        milestones: List<MilestoneModel>,
    ): String? {
        val pronounCap = if (gender == "girl") "Elle" else "Il"
        val agreement = if (gender == "girl") "e" else ""
        val age = formatAge(birthDate)

        val sorted = milestones.sortedBy { it.date }
        val milestonesText = buildString {
            for (m in sorted) {
                val cat = getMilestoneCategoryById(m.type)
                val sub = m.subType?.let { getMilestoneSubTypeById(m.type, it) }
                val label = sub?.label ?: cat.label
                val dateStr = m.dateLabel ?: formatDateFr(m.date, datePrecisionFromString(m.datePrecision))
                if (m.type == "taille_poids") {
                    val parts = listOfNotNull(m.weightKg?.let { "$it kg" }, m.heightCm?.let { "$it cm" })
                    if (parts.isNotEmpty()) appendLine("• [$dateStr] $label : ${parts.joinToString(", ")}")
                } else if (m.rawContent.isNotEmpty()) {
                    appendLine("• [$dateStr] $label : ${m.rawContent}")
                }
            }
        }.ifEmpty { "(aucun souvenir enregistré pour l'instant)" }

        val prompt = """Tu es l'auteur de Bloom, une application qui crée le livre de vie des enfants.

Écris une histoire belle et complète (500 à 700 mots) qui raconte la vie de $childName depuis sa naissance jusqu'à aujourd'hui.

Consignes :
- Écris à la 3ème personne ("$childName fit...", "$pronounCap découvrit...")
- Le genre est ${if (gender == "girl") "féminin" else "masculin"}
- $animalEmoji $animalName le $animalType est le compagnon fidèle de $childName
- Intègre les vrais souvenirs ci-dessous de façon naturelle dans le récit, dans l'ordre chronologique
- Ton : chaleureux, littéraire, un peu magique
- Langue : français soigné
- Termine par une phrase ouverte sur l'avenir

Informations :
- Prénom : $childName
- Né$agreement le : ${formatDate(birthDate)}
- Âge : $age
- Compagnon : $animalEmoji $animalName le $animalType

Souvenirs à intégrer (chronologiques) :
$milestonesText

Génère uniquement l'histoire, sans titre."""
        return call(prompt, maxTokens = 1200)
    }

    private suspend fun call(prompt: String, maxTokens: Int): String? = try {
        val body = client.post(apiUrl) {
            header("x-api-key", apiKey)
            header("anthropic-version", "2023-06-01")
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("model", "claude-sonnet-4-6")
                put("max_tokens", maxTokens)
                putJsonArray("messages") {
                    addJsonObject {
                        put("role", "user")
                        put("content", prompt)
                    }
                }
            }.toString())
        }.body<JsonObject>()
        body["content"]?.jsonArray?.firstOrNull()?.jsonObject
            ?.get("text")?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) { null }

    private fun formatAge(birth: LocalDateTime): String {
        val now = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault())
        val months = (now.year - birth.year) * 12 + now.monthNumber - birth.monthNumber
        if (months < 12) return "$months mois"
        val years = months / 12
        val rem = months % 12
        return if (rem == 0) "$years an${if (years > 1) "s" else ""}"
        else "$years an${if (years > 1) "s" else ""} et $rem mois"
    }

    private fun formatDate(d: LocalDateTime) =
        "${d.dayOfMonth.toString().padStart(2, '0')}/${d.monthNumber.toString().padStart(2, '0')}/${d.year}"
}
