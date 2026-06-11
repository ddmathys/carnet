package com.bloom.core.constants

data class MilestoneSubType(
    val id: String,
    val label: String,
    val hasFreeText: Boolean = false,
)

data class MilestoneCategory(
    val id: String,
    val label: String,
    val emoji: String,
    val description: String = "",
    val subTypes: List<MilestoneSubType> = emptyList(),
    val isLegacy: Boolean = false,
)

val kMilestoneCategories = listOf(
    // ── 20 catégories principales (ordre développemental) ──────────────────────
    MilestoneCategory("naissance",            "Naissance",                    "🍼",  "Date, lieu, premières émotions"),
    MilestoneCategory("retour_maison",        "Retour à la maison",           "🏡",  "Découverte du cocon familial"),
    MilestoneCategory("premieres_nuits",      "Premières nuits",              "😴",  "Sommeil (ou pas 😅)"),
    MilestoneCategory("premiers_repas",       "Premiers repas",               "🍼",  "Biberon, allaitement"),
    MilestoneCategory("premiers_sourires",    "Premiers sourires",            "😊",  "Interaction avec les parents"),
    MilestoneCategory("premiers_sons",        "Premiers sons",                "🗣️",  "Gazouillis, babillage"),
    MilestoneCategory("se_retourner",         "Se retourner",                 "🔄",  "Première mobilité"),
    MilestoneCategory("ramper",               "Ramper",                       "🧎",  "Exploration du monde"),
    MilestoneCategory("s_asseoir",            "S'asseoir",                    "🪑",  "Autonomie qui commence"),
    MilestoneCategory("premiers_pas",         "Premiers pas",                 "👣",  "Moment clé émotionnel"),
    MilestoneCategory("premiers_mots",        "Premiers mots",                "🗨️",  "\"maman\", \"papa\", etc."),
    MilestoneCategory("diversification",      "Diversification alimentaire",  "🍽️",  "Découverte des goûts"),
    MilestoneCategory("premier_anniversaire", "Premier anniversaire",         "🎂",  "Grande étape symbolique"),
    MilestoneCategory("doudou",               "Objet ou doudou préféré",      "🧸",  "Attachement émotionnel"),
    MilestoneCategory("interactions_sociales","Premières interactions",       "👶",  "Avec d'autres enfants"),
    MilestoneCategory("premieres_activites",  "Premières activités",          "🎨",  "Dessins, jeux, créativité"),
    MilestoneCategory("routine",              "Routine quotidienne",          "🚿",  "Bain, coucher, habitudes"),
    MilestoneCategory("emotions_fortes",      "Premières émotions fortes",    "😡",  "Colère, peur, joie intense"),
    MilestoneCategory("entree_creche",        "Entrée en crèche / école",     "🏫",  "Séparation + nouvelle phase"),
    MilestoneCategory("grande_reussite",      "Première grande réussite",     "🌟",  "Propre, vélo, apprentissage clé"),
    // ── Catégories legacy ─────────────────────────────────────────────────────
    MilestoneCategory(
        id = "parole", label = "Première parole", emoji = "💬", isLegacy = true,
        subTypes = listOf(
            MilestoneSubType("premier_mot",    "Premier mot",         hasFreeText = true),
            MilestoneSubType("premiere_phrase","Première phrase",     hasFreeText = true),
            MilestoneSubType("premier_papa",   "Premier \"papa\""),
            MilestoneSubType("premier_maman",  "Premier \"maman\""),
            MilestoneSubType("autre_parole",   "Autre",               hasFreeText = true),
        )
    ),
    MilestoneCategory(
        id = "mouvement", label = "Premier mouvement", emoji = "🏃", isLegacy = true,
        subTypes = listOf(
            MilestoneSubType("retourne",      "1ère fois retourné(e)"),
            MilestoneSubType("assis",         "Assis(e)"),
            MilestoneSubType("sur_genoux",    "Sur les genoux"),
            MilestoneSubType("debout",        "Debout"),
            MilestoneSubType("rampe",         "Avancé en rampant"),
            MilestoneSubType("quatre_pattes", "Avancé sur les genoux"),
            MilestoneSubType("marche",        "Avancé debout"),
        )
    ),
    MilestoneCategory("taille_poids", "Taille & Poids",  "📊", isLegacy = true),
    MilestoneCategory("anecdote",     "Anecdote",        "📖", isLegacy = true),
)

fun getMilestoneCategoryById(id: String): MilestoneCategory =
    kMilestoneCategories.firstOrNull { it.id == id } ?: kMilestoneCategories.last()

fun getMilestoneSubTypeById(categoryId: String, subTypeId: String): MilestoneSubType? =
    getMilestoneCategoryById(categoryId).subTypes.firstOrNull { it.id == subTypeId }

fun getMilestoneCategoryOrder(typeId: String): Int {
    val idx = kMilestoneCategories.indexOfFirst { it.id == typeId }
    return if (idx == -1) 999 else idx
}
