package com.bloom.core.services

import com.bloom.core.constants.getMilestoneCategoryById
import com.bloom.core.constants.getMilestoneCategoryOrder
import com.bloom.core.constants.getMilestoneSubTypeById
import com.bloom.core.models.DraftMilestone
import com.bloom.core.models.ExtractedMilestone
import com.bloom.core.models.MilestoneModel
import com.bloom.core.utils.DatePrecision
import com.bloom.core.utils.datePrecisionFromString
import com.bloom.core.utils.formatDateFr
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.http.*
import kotlinx.datetime.*
import kotlinx.serialization.json.*

data class GrowthAnalysis(
    val heightCm: Double? = null,
    val weightKg: Double? = null,
    val notes: String,
)

class DeepSeekService(private val client: HttpClient, private val apiKey: String) {
    private val apiUrl = "https://api.deepseek.com/v1/chat/completions"

    suspend fun generateStory(
        childName: String,
        gender: String,
        birthDate: LocalDateTime,
        animalName: String,
        animalType: String,
        animalEmoji: String,
        animalTraits: String,
        milestones: List<MilestoneModel>,
    ): String? {
        val agreement = if (gender == "girl") "e" else ""
        val age = formatAge(birthDate)

        val sorted = milestones.sortedWith(
            compareBy({ getMilestoneCategoryOrder(it.type) }, { it.date })
        )

        val milestonesText = buildString {
            for (m in sorted) {
                val cat = getMilestoneCategoryById(m.type)
                val sub = m.subType?.let { getMilestoneSubTypeById(m.type, it) }
                val label = sub?.label ?: cat.label
                val dateStr = m.dateLabel ?: formatDateFr(m.date, datePrecisionFromString(m.datePrecision))
                if (m.type == "taille_poids") {
                    val parts = mutableListOf<String>()
                    m.weightKg?.let { parts.add("${it} kg") }
                    m.heightCm?.let { parts.add("${it} cm") }
                    if (parts.isNotEmpty()) appendLine("• [$dateStr] $label : ${parts.joinToString(", ")}")
                } else {
                    val content = if (m.rawContent.isNotEmpty()) " : ${m.rawContent}" else ""
                    appendLine("• [$dateStr] $label$content")
                }
            }
        }.ifEmpty { "(aucun souvenir spécifique enregistré)" }

        val system = """Tu es l'auteur de Bloom, une application qui crée le livre de vie illustré des enfants.
Tu écris des histoires belles, poétiques et émouvantes en français, dans un style livre jeunesse premium.
Chaque histoire doit être divisée en exactement 5 paragraphes bien distincts, séparés par une ligne vide.
Chaque paragraphe fait 3 à 5 phrases. Total : 500 à 600 mots."""

        val user = """Écris une histoire en 5 paragraphes pour $childName, un${agreement} enfant de $age.

Son compagnon fidèle est $animalEmoji $animalName le $animalType — $animalTraits.

Consignes :
- 3ème personne, accords ${if (gender == "girl") "féminins" else "masculins"}
- 5 paragraphes séparés par une ligne vide
- Intègre les souvenirs ci-dessous dans l'ordre donné (ordre développemental), de façon naturelle et poétique
- À chaque grande étape, tisse un parallèle subtil et poétique avec la nature ou le caractère de $animalName le $animalType ($animalTraits)
- Ton : chaleureux, magique, littéraire — comme un vrai livre pour enfants
- Termine par une phrase ouverte sur l'avenir

Né${agreement} le : ${formatDate(birthDate)} — Âge : $age

Souvenirs (dans l'ordre développemental) :
$milestonesText

Génère uniquement les 5 paragraphes, sans titre."""

        return chatCompletion(system = system, user = user, maxTokens = 1500, temperature = 0.85)
    }

    suspend fun analyzeGrowthComment(
        comment: String,
        childName: String,
        previousMeasurements: List<MilestoneModel>,
    ): GrowthAnalysis? {
        val history = previousMeasurements
            .filter { it.heightCm != null || it.weightKg != null }
            .joinToString("\n") { m ->
                val parts = listOfNotNull(
                    m.heightCm?.let { "${it.toInt()}cm" },
                    m.weightKg?.let { "${it}kg" },
                )
                "${formatDate(m.date)}: ${parts.joinToString(", ")}"
            }

        val prompt = buildString {
            append("Tu es un assistant de l'app Bloom pour suivre la croissance des enfants.\n")
            if (history.isNotEmpty()) append("Historique de $childName:\n$history\n\n")
            append("L'utilisateur a écrit: \"$comment\"\n\n")
            append("Extrais toute taille (en cm) et/ou poids (en kg) mentionnés dans ce message.\n")
            append("Réponds UNIQUEMENT en JSON valide, sans markdown ni explication:\n")
            append("""{"heightCm": nombre ou null, "weightKg": nombre ou null, "notes": "résumé en 1 phrase de ce qui a été noté"}""")
        }

        return try {
            val raw = chatCompletion(user = prompt, maxTokens = 150, temperature = 0.1) ?: return null
            val json = raw.stripCodeFences()
            val obj = Json.decodeFromString<JsonObject>(json)
            GrowthAnalysis(
                heightCm = obj["heightCm"]?.jsonPrimitive?.doubleOrNull,
                weightKg = obj["weightKg"]?.jsonPrimitive?.doubleOrNull,
                notes = obj["notes"]?.jsonPrimitive?.contentOrNull ?: "",
            )
        } catch (_: Exception) { null }
    }

    suspend fun extractAllMilestonesFromText(text: String): List<DraftMilestone>? {
        val system = """Tu es l'assistant de Bloom, application de journal de vie pour enfants.
Analyse le texte d'un parent et extrais TOUS les souvenirs mentionnés.

Types disponibles : naissance, retour_maison, premieres_nuits, premiers_repas, premiers_sourires, premiers_sons, se_retourner, ramper, s_asseoir, premiers_pas, premiers_mots, diversification, premier_anniversaire, doudou, interactions_sociales, premieres_activites, routine, emotions_fortes, entree_creche, grande_reussite, taille_poids, anecdote

Réponds UNIQUEMENT avec un tableau JSON valide, sans markdown ni explication."""

        val user = """Texte du parent:
"""$text"""

Extrais TOUS les souvenirs et retourne ce tableau JSON:
[{"type":"...","subType":null,"date":"YYYY-MM-DD ou YYYY-MM ou YYYY-Qn ou null","datePrecision":"exact ou month ou quarter ou null","rawContent":"...","weightKg":null,"heightCm":null}]"""

        return try {
            val raw = chatCompletion(system = system, user = user, maxTokens = 6000, temperature = 0.1, timeoutMs = 60_000) ?: return null
            val json = raw.stripCodeFences()
            val array = Json.decodeFromString<JsonArray>(json)
            array.mapNotNull { elem ->
                val obj = elem.jsonObject
                val precision = datePrecisionFromString(obj["datePrecision"]?.jsonPrimitive?.contentOrNull)
                DraftMilestone(
                    type = obj["type"]?.jsonPrimitive?.contentOrNull ?: "anecdote",
                    subType = obj["subType"]?.jsonPrimitive?.contentOrNull,
                    date = parseDate(obj["date"]?.jsonPrimitive?.contentOrNull, precision),
                    datePrecision = precision,
                    rawContent = obj["rawContent"]?.jsonPrimitive?.contentOrNull ?: "",
                    weightKg = obj["weightKg"]?.jsonPrimitive?.doubleOrNull,
                    heightCm = obj["heightCm"]?.jsonPrimitive?.doubleOrNull,
                )
            }
        } catch (_: Exception) { null }
    }

    suspend fun extractMilestoneFromText(text: String): ExtractedMilestone? {
        val system = """Tu es l'assistant de Bloom, application de journal de vie pour enfants.
Analyse la note d'un parent et extrais LE souvenir principal (un seul).
Types : naissance, retour_maison, premieres_nuits, premiers_repas, premiers_sourires, premiers_sons, se_retourner, ramper, s_asseoir, premiers_pas, premiers_mots, diversification, premier_anniversaire, doudou, interactions_sociales, premieres_activites, routine, emotions_fortes, entree_creche, grande_reussite, taille_poids, anecdote
Réponds UNIQUEMENT avec un seul objet JSON valide (pas de tableau, pas de markdown)."""

        val user = """Note du parent: "$text"

Extrais LE souvenir principal:
{"type":"...","subType":null,"date":"YYYY-MM-DD ou YYYY-MM ou YYYY-Qn ou null","datePrecision":"exact ou month ou quarter ou null","rawContent":"...","weightKg":null,"heightCm":null}"""

        return try {
            val raw = chatCompletion(system = system, user = user, maxTokens = 600, temperature = 0.1) ?: return null
            val json = raw.stripCodeFences()
            val decoded = Json.decodeFromString<JsonElement>(json)
            val obj = if (decoded is JsonArray) decoded.first().jsonObject else decoded.jsonObject
            val precision = datePrecisionFromString(obj["datePrecision"]?.jsonPrimitive?.contentOrNull)
            ExtractedMilestone(
                type = obj["type"]?.jsonPrimitive?.contentOrNull ?: "anecdote",
                subType = obj["subType"]?.jsonPrimitive?.contentOrNull,
                date = parseDate(obj["date"]?.jsonPrimitive?.contentOrNull, precision),
                datePrecision = precision,
                rawContent = obj["rawContent"]?.jsonPrimitive?.contentOrNull ?: text,
                weightKg = obj["weightKg"]?.jsonPrimitive?.doubleOrNull,
                heightCm = obj["heightCm"]?.jsonPrimitive?.doubleOrNull,
            )
        } catch (_: Exception) { null }
    }

    private suspend fun chatCompletion(
        system: String? = null,
        user: String,
        maxTokens: Int,
        temperature: Double = 0.1,
        timeoutMs: Long = 20_000,
    ): String? = try {
        val messages = buildJsonArray {
            if (system != null) addJsonObject {
                put("role", "system")
                put("content", system)
            }
            addJsonObject {
                put("role", "user")
                put("content", user)
            }
        }
        val body = client.post(apiUrl) {
            header(HttpHeaders.Authorization, "Bearer $apiKey")
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("model", "deepseek-chat")
                put("messages", messages)
                put("max_tokens", maxTokens)
                put("temperature", temperature)
            }.toString())
        }.body<JsonObject>()
        body["choices"]?.jsonArray?.firstOrNull()?.jsonObject
            ?.get("message")?.jsonObject
            ?.get("content")?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) { null }

    private fun parseDate(dateStr: String?, precision: DatePrecision): LocalDateTime? {
        if (dateStr == null) return null
        return try {
            when (precision) {
                DatePrecision.QUARTER -> {
                    val parts = dateStr.split("-Q")
                    if (parts.size == 2) {
                        val year = parts[0].toInt()
                        val quarter = parts[1].toInt()
                        LocalDateTime(year, (quarter - 1) * 3 + 1, 1, 0, 0)
                    } else null
                }
                DatePrecision.MONTH -> {
                    val parts = dateStr.split("-")
                    if (parts.size >= 2) LocalDateTime(parts[0].toInt(), parts[1].toInt(), 1, 0, 0)
                    else null
                }
                DatePrecision.EXACT -> {
                    val inst = Instant.parse("${dateStr}T00:00:00Z")
                    inst.toLocalDateTime(TimeZone.UTC)
                }
            }
        } catch (_: Exception) { null }
    }

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

private fun String.stripCodeFences() = trim()
    .removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
