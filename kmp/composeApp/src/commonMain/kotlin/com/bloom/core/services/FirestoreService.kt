package com.bloom.core.services

import com.bloom.core.config.AppConfig
import com.bloom.core.models.ChildModel
import com.bloom.core.models.MilestoneModel
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.http.*
import kotlinx.datetime.*
import kotlinx.serialization.json.*

class FirestoreService(
    private val client: HttpClient,
    private val auth: FirebaseAuthService,
) {
    private val projectId = AppConfig.FIREBASE_PROJECT_ID
    private val base = "https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents"

    private fun authHeader() = "Bearer ${auth.currentUser?.idToken ?: ""}"

    // ─── Children ─────────────────────────────────────────────────────────────

    suspend fun getChildren(parentId: String): Result<List<ChildModel>> = runCatching {
        val body = client.post("$base:runQuery") {
            header(HttpHeaders.Authorization, authHeader())
            contentType(ContentType.Application.Json)
            setBody(structuredQuery("children", "parentId", parentId))
        }.body<JsonArray>()
        body.mapNotNull { it.jsonObject["document"]?.jsonObject?.toChild() }
    }

    suspend fun addChild(child: ChildModel): Result<ChildModel> = runCatching {
        val body = client.post("$base/children") {
            header(HttpHeaders.Authorization, authHeader())
            contentType(ContentType.Application.Json)
            setBody(child.toFirestoreJson())
        }.body<JsonObject>()
        val id = body["name"]?.jsonPrimitive?.content?.substringAfterLast("/") ?: ""
        child.copy(id = id)
    }

    suspend fun deleteChild(childId: String): Result<Unit> = runCatching {
        client.delete("$base/children/$childId") {
            header(HttpHeaders.Authorization, authHeader())
        }
        Unit
    }

    // ─── Milestones ────────────────────────────────────────────────────────────

    suspend fun getMilestones(childId: String): Result<List<MilestoneModel>> = runCatching {
        val body = client.post("$base:runQuery") {
            header(HttpHeaders.Authorization, authHeader())
            contentType(ContentType.Application.Json)
            setBody(structuredQuery("milestones", "childId", childId))
        }.body<JsonArray>()
        body.mapNotNull { it.jsonObject["document"]?.jsonObject?.toMilestone() }
            .sortedByDescending { it.date }
    }

    suspend fun addMilestone(m: MilestoneModel): Result<MilestoneModel> = runCatching {
        val body = client.post("$base/milestones") {
            header(HttpHeaders.Authorization, authHeader())
            contentType(ContentType.Application.Json)
            setBody(m.toFirestoreJson())
        }.body<JsonObject>()
        val id = body["name"]?.jsonPrimitive?.content?.substringAfterLast("/") ?: ""
        m.copy(id = id)
    }

    suspend fun updateMilestone(m: MilestoneModel): Result<Unit> = runCatching {
        client.patch("$base/milestones/${m.id}") {
            header(HttpHeaders.Authorization, authHeader())
            contentType(ContentType.Application.Json)
            setBody(m.toFirestoreJson())
        }
        Unit
    }

    suspend fun deleteMilestone(milestoneId: String): Result<Unit> = runCatching {
        client.delete("$base/milestones/$milestoneId") {
            header(HttpHeaders.Authorization, authHeader())
        }
        Unit
    }

    // ─── Firestore helpers ─────────────────────────────────────────────────────

    private fun structuredQuery(collection: String, field: String, value: String) =
        buildJsonObject {
            putJsonObject("structuredQuery") {
                putJsonArray("from") { addJsonObject { put("collectionId", collection) } }
                putJsonObject("where") {
                    putJsonObject("fieldFilter") {
                        putJsonObject("field") { put("fieldPath", field) }
                        put("op", "EQUAL")
                        putJsonObject("value") { put("stringValue", value) }
                    }
                }
                putJsonArray("orderBy") {
                    addJsonObject {
                        putJsonObject("field") { put("fieldPath", "createdAt") }
                        put("direction", "ASCENDING")
                    }
                }
            }
        }.toString()

    private fun JsonObject.str(key: String): String? =
        this[key]?.jsonObject?.get("stringValue")?.jsonPrimitive?.contentOrNull

    private fun JsonObject.dbl(key: String): Double? =
        this[key]?.jsonObject?.let {
            it["doubleValue"]?.jsonPrimitive?.doubleOrNull
                ?: it["integerValue"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()
        }

    private fun JsonObject.ts(key: String): LocalDateTime? {
        val v = this[key]?.jsonObject?.get("timestampValue")?.jsonPrimitive?.contentOrNull
            ?: return null
        return try { Instant.parse(v).toLocalDateTime(TimeZone.UTC) } catch (_: Exception) { null }
    }

    private fun JsonObject.toChild(): ChildModel? {
        val id = this["name"]?.jsonPrimitive?.content?.substringAfterLast("/") ?: return null
        val f = this["fields"]?.jsonObject ?: return null
        return ChildModel(
            id = id,
            parentId = f.str("parentId") ?: "",
            firstName = f.str("firstName") ?: "",
            birthDate = f.ts("birthDate") ?: return null,
            animalId = f.str("animalId") ?: "fox",
            animalName = f.str("animalName") ?: "Roux",
            coverColor = f.str("coverColor") ?: "#7A9E7E",
            gender = f.str("gender") ?: "boy",
        )
    }

    private fun JsonObject.toMilestone(): MilestoneModel? {
        val id = this["name"]?.jsonPrimitive?.content?.substringAfterLast("/") ?: return null
        val f = this["fields"]?.jsonObject ?: return null
        val now = Clock.System.now().toLocalDateTime(TimeZone.UTC)
        return MilestoneModel(
            id = id,
            childId = f.str("childId") ?: "",
            type = f.str("type") ?: "anecdote",
            subType = f.str("subType"),
            date = f.ts("date") ?: now,
            datePrecision = f.str("datePrecision") ?: "exact",
            dateLabel = f.str("dateLabel"),
            rawContent = f.str("rawContent") ?: "",
            aiNarration = f.str("aiNarration"),
            photoUrl = f.str("photoUrl"),
            weightKg = f.dbl("weightKg"),
            heightCm = f.dbl("heightCm"),
            createdAt = f.ts("createdAt") ?: now,
        )
    }

    private fun ChildModel.toFirestoreJson() = buildJsonObject {
        putJsonObject("fields") {
            putJsonObject("parentId")  { put("stringValue", parentId) }
            putJsonObject("firstName") { put("stringValue", firstName) }
            putJsonObject("birthDate") { put("timestampValue", birthDate.toInstant(TimeZone.UTC).toString()) }
            putJsonObject("animalId")  { put("stringValue", animalId) }
            putJsonObject("animalName"){ put("stringValue", animalName) }
            putJsonObject("coverColor"){ put("stringValue", coverColor) }
            putJsonObject("gender")    { put("stringValue", gender) }
            putJsonObject("createdAt") { put("timestampValue", Clock.System.now().toString()) }
        }
    }.toString()

    private fun MilestoneModel.toFirestoreJson() = buildJsonObject {
        putJsonObject("fields") {
            putJsonObject("childId")      { put("stringValue", childId) }
            putJsonObject("type")         { put("stringValue", type) }
            if (subType != null) putJsonObject("subType") { put("stringValue", subType) }
            else putJsonObject("subType") { put("nullValue", "NULL_VALUE") }
            putJsonObject("date")         { put("timestampValue", date.toInstant(TimeZone.UTC).toString()) }
            putJsonObject("datePrecision"){ put("stringValue", datePrecision) }
            if (dateLabel != null) putJsonObject("dateLabel") { put("stringValue", dateLabel) }
            putJsonObject("rawContent")   { put("stringValue", rawContent) }
            if (aiNarration != null) putJsonObject("aiNarration") { put("stringValue", aiNarration) }
            if (weightKg != null)    putJsonObject("weightKg") { put("doubleValue", weightKg) }
            if (heightCm != null)    putJsonObject("heightCm") { put("doubleValue", heightCm) }
            putJsonObject("createdAt")    { put("timestampValue", createdAt.toInstant(TimeZone.UTC).toString()) }
        }
    }.toString()
}
