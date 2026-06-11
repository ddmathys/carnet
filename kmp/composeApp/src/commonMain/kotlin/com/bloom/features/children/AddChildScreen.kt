package com.bloom.features.children

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bloom.core.constants.Animal
import com.bloom.core.constants.kAnimals
import com.bloom.core.di.ServiceLocator
import com.bloom.core.models.ChildModel
import com.bloom.core.theme.AppColors
import com.bloom.features.navigation.AppRouter
import com.bloom.features.navigation.Screen
import kotlinx.coroutines.launch
import kotlinx.datetime.LocalDateTime

private val BOY_COLORS = listOf(
    "#7EC8C8", "#6BB8A8", "#5B9EA0", "#4A9BBD", "#5F8FA8", "#7BADC0", "#89B4C9", "#6BA3C0",
)
private val GIRL_COLORS = listOf(
    "#C4956A", "#D4A373", "#C9956A", "#B8866A", "#D4956A", "#C49070", "#BF8C78", "#D4A06A",
)

@Composable
fun AddChildScreen() {
    var step by remember { mutableStateOf(0) }
    var gender by remember { mutableStateOf("") }
    var selectedAnimal by remember { mutableStateOf(kAnimals.first()) }
    var firstName by remember { mutableStateOf("") }
    var birthDateInput by remember { mutableStateOf("") }
    var selectedColor by remember { mutableStateOf(BOY_COLORS.first()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Scaffold(
        containerColor = AppColors.Beige,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(when (step) { 0 -> "Fille ou garçon ?" 1 -> "Choisis un animal" else -> "Informations" }) },
                navigationIcon = {
                    if (step > 0 || AppRouter.canGoBack) {
                        IconButton(onClick = { if (step > 0) step-- else AppRouter.back() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Retour")
                        }
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = AppColors.Cream),
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (step) {
                0 -> GenderStep(
                    onSelect = { g ->
                        gender = g
                        selectedColor = if (g == "boy") BOY_COLORS.first() else GIRL_COLORS.first()
                        step = 1
                    },
                )
                1 -> AnimalStep(
                    onSelect = { animal -> selectedAnimal = animal; step = 2 },
                )
                2 -> InfoStep(
                    gender = gender,
                    selectedAnimal = selectedAnimal,
                    firstName = firstName,
                    onFirstNameChange = { firstName = it },
                    birthDateInput = birthDateInput,
                    onBirthDateChange = { birthDateInput = it },
                    selectedColor = selectedColor,
                    onColorChange = { selectedColor = it },
                    colorOptions = if (gender == "boy") BOY_COLORS else GIRL_COLORS,
                    loading = loading,
                    error = error,
                    onSave = {
                        val uid = ServiceLocator.authService.currentUser?.uid
                        if (uid == null) { error = "Non connecté"; return@InfoStep }
                        val birthDate = parseDateInput(birthDateInput)
                        if (birthDate == null) { error = "Date invalide (JJ/MM/AAAA)"; return@InfoStep }
                        if (firstName.isBlank()) { error = "Prénom requis"; return@InfoStep }
                        scope.launch {
                            loading = true; error = null
                            val child = ChildModel(
                                parentId = uid,
                                firstName = firstName.trim(),
                                birthDate = birthDate,
                                animalId = selectedAnimal.id,
                                animalName = selectedAnimal.defaultCompanionName,
                                coverColor = selectedColor,
                                gender = gender,
                            )
                            ServiceLocator.firestoreService.addChild(child)
                                .onSuccess { AppRouter.navigateAndClear(Screen.Home) }
                                .onFailure { error = "Erreur lors de la sauvegarde." }
                            loading = false
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun GenderStep(onSelect: (String) -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("👶", fontSize = 72.sp)
        Spacer(Modifier.height(24.dp))
        Text("C'est une fille ou un garçon ?", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
        Spacer(Modifier.height(32.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            GenderCard("Garçon", "💙", AppColors.Sage, Modifier.weight(1f)) { onSelect("boy") }
            GenderCard("Fille", "🩷", AppColors.Earth, Modifier.weight(1f)) { onSelect("girl") }
        }
    }
}

@Composable
private fun GenderCard(label: String, emoji: String, color: Color, modifier: Modifier, onClick: () -> Unit) {
    Card(
        modifier = modifier.height(120.dp).clickable(onClick = onClick),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = color.copy(alpha = 0.15f)),
    ) {
        Column(
            Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(emoji, fontSize = 36.sp)
            Spacer(Modifier.height(8.dp))
            Text(label, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold, color = color))
        }
    }
}

@Composable
private fun AnimalStep(onSelect: (Animal) -> Unit) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Spacer(Modifier.height(8.dp))
        Text(
            "Quel est son compagnon ?",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
            modifier = Modifier.padding(horizontal = 8.dp),
        )
        Text("Cet animal l'accompagnera dans son histoire.", color = AppColors.TextMedium, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
        Spacer(Modifier.height(16.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(kAnimals) { animal ->
                AnimalCard(animal, onClick = { onSelect(animal) })
            }
        }
    }
}

@Composable
private fun AnimalCard(animal: Animal, onClick: () -> Unit) {
    Card(
        modifier = Modifier.aspectRatio(1f).clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White),
    ) {
        Column(
            Modifier.fillMaxSize().padding(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(animal.emoji, fontSize = 32.sp)
            Spacer(Modifier.height(4.dp))
            Text(animal.name, fontSize = 11.sp, color = AppColors.TextMedium)
        }
    }
}

@Composable
private fun InfoStep(
    gender: String,
    selectedAnimal: Animal,
    firstName: String,
    onFirstNameChange: (String) -> Unit,
    birthDateInput: String,
    onBirthDateChange: (String) -> Unit,
    selectedColor: String,
    onColorChange: (String) -> Unit,
    colorOptions: List<String>,
    loading: Boolean,
    error: String?,
    onSave: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
    ) {
        Text(
            "${selectedAnimal.emoji} ${selectedAnimal.defaultCompanionName} et...",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
        )
        Spacer(Modifier.height(24.dp))

        OutlinedTextField(
            value = firstName,
            onValueChange = onFirstNameChange,
            label = { Text("Prénom") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = birthDateInput,
            onValueChange = onBirthDateChange,
            label = { Text("Date de naissance (JJ/MM/AAAA)") },
            placeholder = { Text("ex: 15/05/2023") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = AppColors.Sage),
        )
        Spacer(Modifier.height(20.dp))

        Text("Couleur du profil", style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium))
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            colorOptions.take(6).forEach { hex ->
                val color = hex.hexToColor()
                val selected = hex == selectedColor
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(color)
                        .then(if (selected) Modifier.border(3.dp, AppColors.TextDark, CircleShape) else Modifier)
                        .clickable { onColorChange(hex) },
                )
            }
        }

        error?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = AppColors.Error, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(32.dp))

        if (loading) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppColors.Sage)
            }
        } else {
            Button(
                onClick = onSave,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = AppColors.Sage),
                shape = MaterialTheme.shapes.medium,
            ) {
                Text("Créer le profil", fontWeight = FontWeight.Medium)
            }
        }
    }
}

fun parseDateInput(input: String): LocalDateTime? {
    val parts = input.trim().split("/")
    if (parts.size != 3) return null
    val day = parts[0].toIntOrNull() ?: return null
    val month = parts[1].toIntOrNull() ?: return null
    val year = parts[2].toIntOrNull() ?: return null
    return try { LocalDateTime(year, month, day, 0, 0) } catch (_: Exception) { null }
}
