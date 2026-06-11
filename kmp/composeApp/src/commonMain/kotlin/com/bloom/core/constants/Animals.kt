package com.bloom.core.constants

data class Animal(
    val id: String,
    val emoji: String,
    val name: String,
    val defaultCompanionName: String,
    val storyTraits: String,
    val isPremium: Boolean = false,
)

val kAnimals = listOf(
    Animal("fox",       "🦊", "Renard",     "Roux",     "curieux, malicieux, vif et espiègle"),
    Animal("rabbit",    "🐰", "Lapin",      "Noisette", "doux, timide, bondissant et tendre"),
    Animal("bear",      "🐻", "Ours",       "Balou",    "chaleureux, protecteur, grand et câlin"),
    Animal("dino",      "🦕", "Dinosaure",  "Dino",     "aventurier, unique, plein d'énergie et de découvertes"),
    Animal("penguin",   "🐧", "Pingouin",   "Bleu",     "élégant, fidèle, drôle et maladroit mais attachant"),
    Animal("mouse",     "🐭", "Souris",     "Mimi",     "petit mais courageux, curieux et toujours en mouvement"),
    Animal("cat",       "🐱", "Chat",       "Minou",    "indépendant, curieux, agile et infiniment affectueux"),
    Animal("dog",       "🐶", "Chien",      "Filou",    "loyal, joyeux, joueur et toujours présent"),
    Animal("tiger",     "🐯", "Tigre",      "Raja",     "courageux, puissant, sauvage et tendre à la fois"),
    Animal("giraffe",   "🦒", "Girafe",     "Nala",     "élancée, douce, observatrice et majestueuse"),
    Animal("crocodile", "🐊", "Crocodile",  "Croco",    "patient, fort, ancien et sage, protecteur féroce"),
)

fun getAnimalById(id: String): Animal = kAnimals.firstOrNull { it.id == id } ?: kAnimals.first()
